# encoding: UTF-8 

require 'octokit'
require 'json'
require 'open3'
require 'pathname'
require 'active_support/core_ext/hash'
require 'find'
require 'logger'
require 'fileutils'
require 'ostruct'
require 'yaml'
require 'base64'


def count_files(client, results_repository, results_path)
  files = github_query(client) { client.contents(results_repository, :path=>results_path) }

  file_count = 0

  files.each{ |file|
    if file.type == "dir"
      # Scan sub-folder
      file_count += count_files(client, results_repository, file.path)
    elsif file.type == "file"
      file_count += 1
    end
  }

  file_count
end

def clean_up(client, repository, results_repository, results_path, age_limit, limits)
  if $logger.nil?
    logger = Logger.new(STDOUT)
  else
    logger = $logger
  end

  file_count = count_files(client, results_repository, results_path)
  limit_reached = (file_count >= limits["history_total_file_limit"])

  logger.info("File limits: total files found: #{file_count}, limits set to: #{limits["history_total_file_limit"]}, history file limit hit: #{limit_reached}")

  branches = limits["history_long_running_branch_names"]
  feature_branch_limit = limits["history_feature_branch_file_limit"]
  long_running_branch_limit = limits["history_long_running_branch_file_limit"]

  if limit_reached 
    logger.info("Total file limits reached, long running branch names: '#{branches}', feature branch file limit: '#{feature_branch_limit}', long running branch file limit: '#{long_running_branch_limit}'")
  end

  # todo properly handle paginated results from github
  _branches = github_query(client) { client.branches(repository, :per_page => 200) }
  _releases = github_query(client) { client.releases(repository, :per_page => 200) }
  _pull_requests = github_query(client) { client.pull_requests(repository, :state=>"open", :per_page => 50) }

  clean_up_impl(client, repository, results_repository, results_path, age_limit,
                      limit_reached, branches, feature_branch_limit, long_running_branch_limit, _branches, _releases, _pull_requests)
end

def clean_up_impl(client, repository, results_repository, results_path, age_limit,
                 limit_reached, long_running_branches, feature_branch_limit, long_running_branch_limit, branches, releases, pull_requests)
  if $logger.nil?
    logger = Logger.new(STDOUT)
  else
    logger = $logger
  end

  # be sure to get files first and branches second so we don't race
  # to delete the results for a branch that doesn't yet exist
  files = github_query(client) { client.contents(results_repository, :path=>results_path) }

  folder_contains_files = false

  files.each{ |file|
    if file.type == "dir"
      # Scan sub-folder
      clean_up_impl(client, repository, results_repository, file.path, age_limit, 
                    limit_reached, long_running_branches, feature_branch_limit, long_running_branch_limit, branches, releases, pull_requests)
    elsif file.type == "file"
      folder_contains_files = true
    end
  }

  unless folder_contains_files
    # No reason to continue from here if no files are found
    return
  end

  branch_history_limit = 20
  file_age_limit = 9000

  if limit_reached
    if results_path.end_with?(*long_running_branches)
      branch_history_limit = long_running_branch_limit
      logger.info("Long running branch limit reached: #{branch_history_limit}")
    else
      branch_history_limit = feature_branch_limit
      logger.info("Feature branch limit reached: #{branch_history_limit}")
    end
  end

  # These are the absolute failsafe limits required by github
  # if we are approaching 1000 files in a single directory
  if files.size > 800
    if files.size > 999
      branch_history_limit = 1
      file_age_limit = age_limit + 1
    else
      branch_history_limit = [5, branch_history_limit].min
      file_age_limit = 60
    end
    logger.info("Hitting directory size limit #{files.size}, reducing history to #{branch_history_limit} data points")
  end

  files_for_deletion = []
  branches_deleted = Set.new
  prs_deleted = Set.new
  file_branch = Hash.new
  branch_files = Hash.new

  releases.each { |release|
    logger.debug("Loaded release: '#{release.tag_name}'")
  }

  files.each { |file| 
    if file.type == "file"
      logger.debug("Examining file #{file.sha} #{file.path}")

      file_data = nil

      begin
        file_content = Base64.decode64(github_query(client) { client.blob(results_repository, file.sha).content })
        #      file_content = Base64.decode64(github_query(client) { client.contents(results_repository, :path=>file.path) })
        file_data = YAML.load(file_content)
      rescue Psych::SyntaxError
        logger.info("Results file has bad data, deleting. #{file.path}")
        files_for_deletion << file
        next
      end

      branch_name = file_data["branch_name"]


      days_old = (DateTime.now - file_data["date"].to_datetime).to_f
      if days_old > file_age_limit
        logger.debug("Results file has been around for #{days_old} days. Deleting.")
        files_for_deletion << file
        next
      end

      if file.path =~ /DailyTaskRun$/
        logger.debug("DailyTaskRun created on: #{file_data["date"]}")
        days_since_run = (DateTime.now - file_data["date"].to_datetime).to_f
        if days_since_run > 5
          logger.debug("Deleting old DailyTaskRun file #{file.path}")
          files_for_deletion << file
        end

      elsif !file_data["pending"]
        if !file_data["pull_request_issue_id"].nil? && file_data["pull_request_issue_id"] != ""
          pr_found = false
          pull_requests.each{ |pr|
#            logger.debug("Comparing '#{pr.number}' to '#{file_data["pull_request_issue_id"]}'");
            if pr.number.to_s == file_data["pull_request_issue_id"].to_s
              # matching open pr found
              pr_found = true
              break
            end
          }
          unless pr_found
            logger.info("PR #{file_data["pull_request_issue_id"]} not found, queuing results file for deletion: #{file_data["title"]}")
            files_for_deletion << file
            prs_deleted << file_data["pull_request_issue_id"]
          end

#        elsif branch_name.nil? && file_data["pull_request_issue_id"].nil? && file_data["tag_name"].nil?
#          logger.error("Found file with no valid tracking data... deleting #{file_data["title"]}")
#          files_for_deletion << file

        elsif !branch_name.nil? && branch_name != "" && (file_data["pull_request_issue_id"].nil? || file_data["pull_request_issue_id"] == "")
          logger.debug("Examining branch #{branch_name} commit #{file_data["commit_sha"]}")

          file_key = {:device_id => file_data["device_id"], :branch_name => branch_name}
          file_data = {:date => file_data["date"], :file => file}

          if branch_files[file_key].nil?
            branch_files[file_key] = []
          end
          branch_files[file_key] << file_data

          branch_found = false
          branches.each{ |b|
            if b.name == branch_name
              branch_found = true
              break
            end
          }

          unless branch_found
            logger.debug("Branch not found, queuing results file for deletion: #{file_data["title"]}")
            files_for_deletion << file
            file_branch[file.path] = branch_name
            branches_deleted << branch_name
          end
        end

      else 
        # is pending
        logger.debug("Pending build was created on: #{file_data["date"]}")
        days_pending = (DateTime.now - file_data["date"].to_datetime).to_f
        if days_pending > 1
          logger.debug("Build has been pending for > 1 day, deleting pending file to try again: #{file_data["title"]}")
          files_for_deletion << file
        end

      end

    end
  }

  logger.info("#{files.size} files found. #{branches.size} active branches found. #{branches_deleted.size} deleted branches found (#{branches_deleted}). #{prs_deleted.size} deleted pull requests found (#{prs_deleted}). #{files_for_deletion.size} files queued for deletion")

  branch_files.each { |key, file_data|
    logger.info("Examining branch data: #{key}")
    file_data.sort_by! { |i| i[:date] }

    # allow at most branch_history_limit results for each device_id / branch_name combination. The newest, specifically
    if file_data.size > branch_history_limit
      file_data[0..file_data.size - (branch_history_limit + 1)].each { |file|
        logger.debug("Marking old branch results file for deletion #{file[:file].path}")
        files_for_deletion << file[:file]
      }
    end
  }


  files_for_deletion.each { |file|
    logger.info("Deleting results file: #{file.path}. Source branch #{file_branch[file.path]} removed, or file too old")
    begin
      github_query(client) { client.delete_contents(results_repository, file.path, "Source branch #{file_branch[file.path]} removed. Deleting results.", file.sha) }
    rescue => e
      logger.error("Error deleting file: #{file.path} for branch #{file_branch[file.path]} message: #{e}")
    end
  }

  true
end

