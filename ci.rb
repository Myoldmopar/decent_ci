#!/usr/bin/env ruby
# encoding: UTF-8 

require 'fileutils'
require 'logger'
require_relative 'lib/build'
require_relative 'cleanup.rb'
require 'optparse'

$logger = Logger.new "decent_ci.log", 10
$created_dirs = []
$current_log_repository = nil
$current_log_deviceid = nil
$current_log_devicename = "#{Socket.gethostname}-#{Socket.ip_address_list.find { |ai| ai.ipv4? && !ai.ipv4_loopback? }.ip_address}"

original_formatter = Logger::Formatter.new
$logger.formatter = proc { |severity, datetime, program_name, msg|

  msg = msg.gsub(/\/\/\S+@github/, "//<redacted>@github")

  unless $current_log_devicename.nil?
    msg = "[#{$current_log_devicename}] #{msg}"
  end

  unless $current_log_deviceid.nil?
    msg = "[#{$current_log_deviceid}] #{msg}"
  end

  unless $current_log_repository.nil?
    msg = "[#{$current_log_repository}] #{msg}"
  end

  res = original_formatter.call(severity, datetime, program_name, msg.dump)
  puts res
  res
}

$logger.info "#{__FILE__} starting"
$logger.debug "#{__FILE__} starting, ARGV: #{ARGV}"
$logger.debug "Logging to decent_ci.log"

options = {}
options[:delay_after_run] = 300
options[:maximum_branch_age] = 30
options[:verbose] = false

opts = OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} [options] <testruntrueorfalse> <githubtoken> <repositoryname> (<repositoryname> ...)"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options[:verbose] = v
  end

  opts.on("-s", "--disable-ssl-verification", "Disable verification of ssl certificates") do |v|
    options[:disable_ssl_verification] = v
  end

  opts.on("--aws-access-key-id=[key]") do |k|
    ENV["AWS_ACCESS_KEY_ID"] = k
    options[:aws_access_key_id] = k
    $logger.debug "aws-access-key-id: #{options[:aws_access_key_id]}"
  end

  opts.on("--aws-secret-access-key=[secret]") do |k|
    ENV["AWS_SECRET_ACCESS_KEY"] = k
    options[:aws_secret_access_key] = k
    $logger.debug "aws-secret-access-key: #{options[:aws_secret_access_key]}"
  end

  opts.on("--delay-after-run=N", Integer, "Time to delay after execution has completed, in seconds. Defaults to 300") do |k|
    options[:delay_after_run] = k
  end

  $logger.info "delay_after_run: #{options[:delay_after_run]}"

  opts.on("--maximum-branch-age=N", Integer, "Maximum age of a commit, in days, that will be built. Defaults to 30.") do |k|
    options[:maximum_branch_age] = k
  end

  $logger.info "maximum_branch_age : #{options[:maximum_branch_age]}"

  opts.on("--trusted_branch=[branch_name]", String, "Branch name to load trusted files from. Defaults to github default branch.") do |k|
    if k != ""
      options[:trusted_branch] = k
    end
  end

  opts.on_tail("-h", "--help", "Show this message") do
    puts opts
    exit
  end
end

opts.parse!

if ARGV.length < 3
  opts.abort(opts.to_s)
end

if options[:verbose]
  $logger.info "Changing log level to DEBUG"
  $logger.level = Logger::DEBUG
else
  $logger.info "Changing log level to INFO"
  $logger.level = Logger::INFO
end

if options[:disable_ssl_verification]
  $logger.warn "Disabling SSL certificate verification"
  require 'openssl'
  OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE # warning: already initialized constant VERIFY_PEER
end

env_dump = ""
ENV.sort.each { |k,v|
  env_dump += "#{k}=#{v}; "
}

$logger.info "Environment: #{env_dump}"

# keep this after the above environment dump so the key isn't included there
ENV["GITHUB_TOKEN"] = ARGV[1]

puts("Configured trusted branch: #{options[:trusted_branch].to_s}")

def get_limits(t_options, t_client, t_repo)

  limits = lambda {
    trusted_branch = t_options[:trusted_branch]
    $logger.info("Loading decent_ci-limits.yaml from #{trusted_branch}")

    begin
      if trusted_branch.nil? || trusted_branch == ""
        content = github_query(t_client) { t_client.contents(t_repo, :path=>".decent_ci-limits.yaml") }
      else
        content = github_query(t_client) { 
          t_client.contents(t_repo, { :path=>".decent_ci-limits.yaml", :ref=>trusted_branch } ) 
        }
      end

      return YAML.load(Base64.decode64(content.content.to_s))
    rescue SyntaxError => e
      $logger.info("'#{e.message}' error while reading limits file")
    rescue Psych::SyntaxError => e
      $logger.info("'#{e.message}' error while reading limits file")
    rescue Octokit::NotFound => e
      $logger.info("No limits file found on this repository, moving on...")
    rescue => e
      $logger.info("'#{e.message}' '#{e.backtrace}' error while reading limits file")
    end

    return {}
  }.()

  if limits["history_total_file_limit"].nil?
    limits["history_total_file_limit"] = 5000
  end

  if limits["history_long_running_branch_names"].nil?
    limits["history_long_running_branch_names"] = %w(develop master)
  end

  if limits["history_feature_branch_file_limit"].nil?
    limits["history_feature_branch_file_limit"] = 5
  end

  if limits["history_long_running_branch_file_limit"].nil?
    limits["history_long_running_branch_file_limit"] = 20
  end

  limits
end

did_any_builds = false

(2..ARGV.length - 1).each {|conf|
  $logger.info "Loading configuration #{ARGV[conf]}"
  $current_log_repository = ARGV[conf]

  begin
    # Loads the list of potential builds and their config files for the given
    b = Build.new(ARGV[1], ARGV[conf], options[:maximum_branch_age])
    test_mode = !(ARGV[0] =~ /false/i)

    $logger.info "Querying for updated branches"
    b.query_branches
    b.query_pull_requests

    did_daily_task = false

    b.results_repositories.each {|repo, results_repo, results_path|
      $logger.info "Checking daily task status for #{repo} #{results_repo} #{results_path}"

      if (test_mode || b.needs_daily_task(results_repo, results_path)) && ENV["DECENT_CI_SKIP_DAILY_TASKS"].nil?
        did_daily_task = true

        count = 0
        succeeded = false
        while count < 5 && !succeeded do
          $logger.info "Executing clean_up task"
          begin
            limits = get_limits(options, b.client, repo)
            clean_up(b.client, repo, results_repo, results_path, options[:maximum_branch_age], limits)
            succeeded = true
          rescue => e
            $logger.error "Error running clean_up #{e} #{e.backtrace}"
          end
          count += 1
        end
      end
    }

    if did_daily_task
      b.pull_request_details.each {|d|

        $logger.debug "PullRequestDetail: #{d}"

        days = (DateTime.now - DateTime.parse(d[:last_updated].to_s)).round

        references = ""

        d[:notification_users].each {|u|
          references += "@#{u} "
        }

        message_to_post = "#{references}it has been #{days} days since this pull request was last updated."

        $logger.debug "Message: #{message_to_post}"

        if days >= d[:aging_pull_requests_numdays]
          if d[:aging_pull_requests_notification]
            $logger.info "Posting Message: #{message_to_post} to issue #{d[:id]}"
            if !test_mode
              b.client.add_comment(d[:repo], d[:id], message_to_post)
            else
              $logger.info "Not actually posting pull request, test mode"
            end
          else
            $logger.info "Not posting pull request age message, posting is disabled for this branch"
          end
        else
          $logger.info "Not posting pull request age message, only post every #{d[:aging_pull_requests_numdays]} days"
        end
      }
    end

    # loop over each potential build
    b.potential_builds.each {|p|

      if p.branch_name
        $logger.info "Working on branch \"#{p.branch_name}\": Looping over compilers"
      elsif p.tag_name
        $logger.info "Working on tag \"#{p.tag_name}\": Looping over compilers"
      end

      p.compilers.each {|compiler|
        begin

          # reset potential build for the next build attempt
          p.next_build
          p.test_run = test_mode

          if p.needs_run compiler
            did_any_builds = true

            $logger.info "Beginning build for #{compiler[:name]} - #{p.descriptive_string}"
            p.post_results compiler, true
            begin

              # We are going to purposely build the branch first before the baseline.
              # In some cases, the branch is merged and deleted before CI completes.
              # By the time CI gets around to it, it first builds the baseline then fails to build the deleted branch.
              # This waste of time can be eliminated by just doing the build of the branch first, it will fail quick.
              # We dont run tests on the branch though -- the baseline will need to be built before running them.

              # First at least get a regression_base variable, it can be nil
              regression_base = b.get_regression_base p

              # Then try to build the branch
              if File.directory?(p.this_src_dir)
                $logger.info "Removing pre-existing branch directory (#{p.this_src_dir})"
                FileUtils.rm_rf(p.this_src_dir)
              end

              # Now we have a fully built and packaged up branch build, time to build the baseline if applicable
              if p.needs_regression_test(compiler) && regression_base
                regression_base.set_as_baseline
                regression_base.test_run = test_mode
                if File.directory?(p.this_regression_dir)
                  $logger.info "Removing pre-existing regressions directory (#{p.this_regression_dir})"
                  FileUtils.rm_rf(p.this_regression_dir)
                end
                p.clone_regression_repository
                if File.directory?(regression_base.this_src_dir)
                  $logger.info "Removing pre-existing baseline directory (#{regression_base.this_src_dir})"
                  FileUtils.rm_rf(regression_base.this_src_dir)
                end
                $logger.info "Beginning regression baseline (#{regression_base.descriptive_string}) build for #{compiler[:name]} - #{p.descriptive_string}"
                regression_base.do_build compiler, nil
                regression_base.do_test compiler, nil
              end

              # Now we have a built branch and baseline if applicable, time to run tests and push results.
              p.do_test compiler, regression_base
              p.do_coverage compiler
              p.do_upload compiler

            rescue => e
              $logger.error "Logging unhandled failure #{e} #{e.backtrace}"
              p.failure = "#{e}\n#{e.backtrace}"
            end

            if compiler[:collect_performance_results]
              p.collect_file_sizes
              p.collect_perf_results
              p.collect_valgrind_counters_results
            end

            p.post_results compiler, false

          else
            $logger.info "Skipping build, already completed, for #{compiler[:name]} #{p.descriptive_string}"
          end
        rescue => e
          $logger.error "Error creating build: #{compiler} #{p.descriptive_string}: #{e} #{e.backtrace}"
        end

      }
    }
  rescue => e
    $logger.fatal "Unable to initiate build system #{e} #{e.backtrace}"
  end

  $current_log_repository = nil
}

if did_any_builds
  $logger.info "Execution completed, since builds were run we wont sleep}"
else
  $logger.info "No builds were run, sleeping for #{options[:delay_after_run]}"
  sleep(options[:delay_after_run])
end
