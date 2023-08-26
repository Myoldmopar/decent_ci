# frozen_string_literal: true

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

require_relative 'codemessage'
require_relative 'decent_exceptions'
require_relative 'testresult'
require_relative 'potentialbuild'
require_relative 'github'

# Top level class that loads the list of potential builds from github
class Build
  attr_reader :client
  attr_accessor :potential_builds

  def initialize(token, repository, max_age)
    @client = Octokit::Client.new(:access_token => token)
    @token = token
    @repository = repository
    @user = github_query(@client) { @client.user }
    github_query(@client) { @user.login }
    @potential_builds = []
    @max_age = max_age
    github_check_rate_limit(@client.last_response.headers)
  end

  def query_for_new_builds
    # Keep a mapping of branch name -> PR number for PRs which are based on non-fork branches
    # That way we can try to comment on the PRs for any associated PR, whether internal or external
    # The only time we will have to revert to commenting on a commit itself is if it is a non-fork branch without a PR
    branch_to_pr_number = {}

    # Thiu section scans for 'external' pull_requests (PRs from repo branches are built as separate branches)
    # This line is where we want to add :accept => 'application/vnd.github.shadow-cat-preview+json' for draft PRs
    pull_requests = github_query(@client) { @client.pull_requests(@repository, :state => 'open', :per_page => 50) }
    pull_requests.each do |p|
      # TODO: p.head.repo can be null if the fork repo is deleted.  Need to protect that here.
      if p.head.repo.nil?
        $logger.info("Skipping potential PR (#{p.number}): Forked repo is null (deleted?)")
      else
        begin
          pb = PotentialBuild.new(@client, @token, p.head.repo.full_name, p.head.sha, p.head.ref, p.head.user.login, p.number, p.base.repo.full_name, p.base.ref)

          if p.head.repo.full_name == p.base.repo.full_name
            # we wont build "internal" PRs in this block, but we will save a map from branch name to PR number
            $logger.info("Skipping pull-request originating from head repo: #{p.number}")
            branch_to_pr_number[p.head.ref] = p.number
            $logger.info("  ...but adding branch name to pr_number hash: #{p.head.ref} => #{p.number}")
          else
            $logger.info("Found an external PR to add to potential_builds: #{p.number}")
            @potential_builds << pb
          end
        rescue DecentCIKnownError => e
          $logger.info("Skipping potential PR (#{p.number}): #{e}")
        rescue => e
          $logger.info("Skipping potential PR (#{p.number}): #{e} #{e.backtrace}")
        end
      end
    end

    # $logger.info("Full hash of branch name to PR number: #{branch_to_pr_number}")

    # TODO: properly handle paginated results from github
    branches = github_query(@client) { @client.branches(@repository, :per_page => 100) }
    branches.each do |b|
      if b.name.include?('#')
        $logger.warn("Skipping branch that starts with hash symbol: #{b.name}")
        next
      end
      $logger.debug("Querying potential build: #{b.name}")
      branch_details = github_query(@client) { @client.branch(@repository, b.name) }
      skip_message_present = false
      begin
        skip_message_present = branch_details.commit.commit.message['[decent_ci_skip]']
      rescue
        # Ignored
      end
      next if skip_message_present && branch_details.name != 'develop' # only skip if we have the msg on a non-develop branch

      begin
        days = (DateTime.now - DateTime.parse(branch_details.commit.commit.author.date.to_s)).round
        if days <= @max_age
          login = 'Unknown'
          if branch_details.commit.author.nil?
            $logger.debug('Commit author is nil, getting login details from committer information')
            login = branch_details.commit.committer.login unless branch_details.commit.committer.nil?

            $logger.debug("Login set to #{login}")
          else
            login = branch_details.commit.author.login
          end

          # while looking through repo-branches, check if there is a PR associated and give it a PR num if so
          associated_pr_num = branch_to_pr_number.fetch(b.name, nil)

          @potential_builds << PotentialBuild.new(@client, @token, @repository, b.commit.sha, b.name, login, associated_pr_num, nil, nil)
          # pb = @potential_builds[-1]
          # $logger.info("Found a branch to add to potential_builds: #{b.name}")
          # $logger.info("ASSOCIATED PR NUMBER IS: #{associated_pr_num}")
          # if !pb.pull_id.nil?
          #   File.open("/tmp/testcomment.txt", 'w') { |f| f.write("Hi, I'm a pretend comment on a PR I hope") }
          #   github_query(@client) { @client.add_comment("NREL/EnergyPlus", pb.pull_id, "OK I am the test comment text :)") }
          # end
        else
          $logger.info("Skipping potential build (#{b.name}), it hasn't been updated in #{days} days")
        end
      rescue DecentCIKnownError => e
        $logger.info("Skipping potential branch (#{b.name}): #{e}")
      rescue => e
        $logger.info("Skipping potential branch (#{b.name}): #{e} #{e.backtrace}")
      end
    end
  end

  def get_regression_base(t_potential_build)
    config = t_potential_build.configuration
    defined_baseline = config.send("regression_baseline_#{t_potential_build.branch_name}")

    default_baseline = config.regression_baseline_default
    default_baseline = 'develop' if default_baseline.nil? && t_potential_build.branch_name != 'develop' && t_potential_build.branch_name != 'master'

    baseline = defined_baseline || default_baseline

    $logger.info("Baseline defined as: '#{baseline}' for branch '#{t_potential_build.branch_name}'")

    baseline = nil if [t_potential_build.branch_name, ''].include? baseline

    $logger.info("Baseline refined to: '#{baseline}' for branch '#{t_potential_build.branch_name}'")

    return nil if baseline.nil? || baseline == ''

    @potential_builds.each do |p|
      # TODO: Protect other fork develop branches from inadvertently becoming the baseline branch
      return p if p.branch_name == baseline
    end

    nil
  end

  def needs_daily_task(results_repo, results_path)
    dateprefix = DateTime.now.utc.strftime('%F')
    document =
      <<-HEADER
---
title: #{dateprefix} Daily Task
tags: daily_task
date: #{DateTime.now.utc.strftime('%F %T')}
repository: #{@repository}
machine_name: #{Socket.gethostname}
machine_ip: #{Socket.ip_address_list.find { |ai| ai.ipv4? && !ai.ipv4_loopback? }.ip_address}
---

      HEADER

    response = github_query(@client) do
      @client.create_contents(
        results_repo,
        "#{results_path}/#{dateprefix}-DailyTaskRun",
        "Commit daily task run file: #{dateprefix}-DailyTaskRun",
        document
      )
    end

    $logger.info("Daily task document sha: #{response.content.sha}")
    true
  rescue
    $logger.info('Daily task file not created, skipping daily task')
    false
  end

  def results_repositories
    s = Set.new
    @potential_builds.each do |p|
      s << [p.configuration.repository, p.configuration.results_repository, p.configuration.results_path] unless p.pull_request?
    end
    s
  end
end
