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
require 'socket'

require_relative 'codemessage'
require_relative 'testresult'
require_relative 'cmake'
require_relative 'configuration'
require_relative 'resultsprocessor'
require_relative 'github'
require_relative 'lcov'
require_relative 'runners'

## Contains the logic flow for executing builds and parsing results
class PotentialBuild
  include CMake
  include Configuration
  include ResultsProcessor
  include Lcov
  include Runners

  attr_reader :tag_name, :commit_sha, :branch_name, :repository
  attr_accessor :test_run, :failure, :pr_num_to_use_for_comment

  def initialize(client, token, repository, commit_sha, branch_name, author, # rubocop:disable Metrics/ParameterLists
                 pull_id, pr_base_repository, pr_base_ref, pr_num_to_use_for_comment = nil)
    @pr_num_to_use_for_comment = pr_num_to_use_for_comment
    @client = client
    @config = load_configuration(repository, commit_sha)
    @config.repository_name = github_query(@client) { @client.repo(repository).name }
    @config.repository = repository
    @config.token = token
    @repository = repository
    @commit_sha = commit_sha
    @branch_name = branch_name
    @author = author

    @buildid = @commit_sha
    @refspec = @branch_name

    @pull_id = pull_id
    @pull_request_base_repository = pr_base_repository
    @pull_request_base_ref = pr_base_ref

    @short_buildid = @commit_sha[0..9]
    unless @pull_id.nil?
      @buildid = "#{@buildid}-PR#{@pull_id}"
      @short_buildid = "#{@short_buildid}-PR#{@pull_id}"
    end

    @test_results = nil
    @test_messages = []
    @build_results = SortedSet.new
    @dateprefix = nil
    @failure = nil
    @test_run = false
    @build_time = nil
    @test_time = nil
    @install_time = nil
    @package_time = nil
    @coverage_lines = 0
    @coverage_total_lines = 0
    @coverage_functions = 0
    @coverage_total_functions = 0
    @coverage_url = nil
    @asset_url = nil
    @acting_as_baseline = false

    @valgrind_counters_results = nil
    @perf_counters_results = nil
    @file_sizes = nil
  end

  def set_as_baseline
    @acting_as_baseline = true
  end

  def compilers
    @config.compilers
  end

  def descriptive_string
    "#{@commit_sha} #{@branch_name} #{@tag_name} #{@buildid}"
  end

  def release?
    !@release_url.nil?
  end

  def pull_request?
    !@pull_id.nil?
  end

  def device_tag(compiler)
    build_type_tag = ''
    build_type_tag = "-#{compiler[:build_tag]}" unless compiler[:build_tag].nil?
    build_type_tag = "#{build_type_tag}-#{compiler[:build_type]}" if compiler[:build_type] !~ /release/i
    build_type_tag
  end

  def device_id(compiler)
    "#{compiler[:architecture]}-#{@config.os}-#{@config.os_release}-#{compiler[:description]}#{device_tag(compiler)}"
  end

  def build_base_name(compiler)
    "#{@config.repository_name}-#{@buildid}-#{device_id(compiler)}"
  end

  def results_file_name(compiler)
    "#{build_base_name compiler}-results.html"
  end

  def short_build_base_name(compiler)
    "#{@config.repository_name}-#{compiler[:architecture]}-#{@config.os}-#{@buildid}"
  end

  def checkout(src_dir)
    # TODO: update this to be a merge, not just a checkout of the pull request branch
    FileUtils.mkdir_p src_dir

    if @pull_id.nil?
      $logger.info("Checking out branch \"#{@refspec}\"")
      _, _, result = run_scripts(
        @config,
        [
          "cd #{src_dir} && git init",
          "cd #{src_dir} && git pull https://#{@config.token}@github.com/#{@repository} \"#{@refspec}\""
        ]
      )

      success = !@commit_sha.nil? && @commit_sha != '' && result.zero?
      _, _, result = run_scripts(@config, ["cd #{src_dir} && git checkout #{@commit_sha}"]) if success
    else
      $logger.info("Checking out PR \"#{@pull_id}\"")
      _, _, result = run_scripts(
        @config,
        [
          "cd #{src_dir} && git init",
          "cd #{src_dir} && git pull https://#{@config.token}@github.com/#{@pull_request_base_repository} refs/pull/#{@pull_id}/head",
          "cd #{src_dir} && git checkout FETCH_HEAD"
        ]
      )
    end

    result.zero?
  end

  def configuration
    @config
  end

  def do_coverage(compiler)
    return nil unless compiler[:coverage_enabled]

    $logger.info("Beginning coverage calculation phase #{release?}")

    build_dir = this_build_dir
    @coverage_total_lines, @coverage_lines, @coverage_total_functions, @coverage_functions = lcov @config, compiler, build_dir
    return if compiler[:coverage_s3_bucket].nil?

    s3_script = "#{File.dirname(File.dirname(__FILE__))}/send_to_s3.py"

    $logger.info('Beginning upload of coverage results to s3')

    out, = run_scripts(
      @config,
      [
        "#{s3_script} #{compiler[:coverage_s3_bucket]} #{get_full_build_name(compiler)} #{build_dir}/lcov-html coverage"
      ]
    )

    @coverage_url = out
    out
  end

  def do_upload(compiler)
    return nil if compiler[:s3_upload].nil?

    $logger.info("Beginning upload phase #{release?} #{!compiler[:s3_upload].nil?}")

    build_dir = this_build_dir

    s3_script = "#{File.dirname(File.dirname(__FILE__))}/send_to_s3.py"

    $logger.info('Beginning upload of build assets to s3')

    out, = run_scripts(
      @config,
      [
        "#{s3_script} #{compiler[:s3_upload_bucket]} #{get_full_build_name(compiler)} #{build_dir}/#{compiler[:s3_upload]} assets"
      ]
    )

    @asset_url = out
    out
  end

  def needs_run(compiler)
    return true if @test_run

    file_names = []
    begin
      files = github_query(@client) { @client.content @config.results_repository, :path => "#{@config.results_path}/#{this_branch_folder}" }

      files.each do |f|
        file_names << f.name
      end
    rescue Octokit::NotFound # rubocop:disable Lint/SuppressedException
      # repository doesn't have a _posts folder yet
    end

    file_names.each do |f|
      return false if f.end_with? results_file_name(compiler)
    end

    true
  end

  def get_initials(str)
    # extracts just the initials from the string
    str.gsub(/[^A-Z0-9.\-a-z_+]/, '').gsub(/[_\-+]./) { |s| s[1].upcase }.sub(/./, &:upcase).gsub(/[^A-Z0-9.]/, '')
  end

  def add_dashes(str)
    str.gsub(/([0-9]{3,})([A-Z])/, '\1-\2').gsub(/([A-Z])([0-9]{3,})/, '\1-\2')
  end

  def get_short_form(str)
    return nil if str.nil?

    if str.length <= 10 && str =~ /[a-zA-Z]/
      str
    elsif (str =~ /.*[A-Z].*/ && str =~ /.*[a-z].*/) || str =~ /.*_.*/ || str =~ /.*-.*/ || str =~ /.*\+.*/
      add_dashes(get_initials(str))
    else
      str.gsub(/[^a-zA-Z0-9.+_]/, '')
    end
  end

  def this_branch_folder
    if !@tag_name.nil? && @tag_name != ''
      add_dashes(get_short_form(@tag_name))
    else
      add_dashes(get_short_form(@branch_name))
    end
  end

  def get_full_build_name(compiler)
    "#{get_short_form(@config.repository_name)}-#{@short_buildid}-#{compiler[:architecture]}-#{get_short_form(compiler[:description])}#{get_short_form(device_tag(compiler))}"
  end

  def this_src_dir
    if @acting_as_baseline
      File.join(Dir.pwd, 'clone_baseline')
    else
      File.join(Dir.pwd, 'clone_branch')
    end
  end

  def this_build_dir
    File.join(this_src_dir, 'build')
  end

  def this_regression_dir
    File.join(Dir.pwd, 'clone_regressions')
  end

  def do_build(compiler, regression_baseline)
    src_dir = this_src_dir
    build_dir = this_build_dir
    start_time = Time.now
    checkout_succeeded = checkout src_dir
    # TODO: Abort if checkout did not succeed...
    this_device_id = device_id compiler
    args = CMakeBuildArgs.new(compiler[:build_type], this_device_id)
    cmake_build compiler, src_dir, build_dir, this_regression_dir, regression_baseline, args if checkout_succeeded
    @build_time = 0 if @build_time.nil?
    @build_time += (Time.now - start_time)
    # TODO: Should we return true here?
  end

  def do_test(compiler, regression_baseline)
    src_dir = this_src_dir
    build_dir = this_build_dir

    build_succeeded = do_build compiler, regression_baseline

    start_time = Time.now
    if ENV['DECENT_CI_SKIP_TEST']
      $logger.debug('Skipping test, DECENT_CI_SKIP_TEST is set in the environment')
    elsif build_succeeded
      cmake_test compiler, src_dir, build_dir, compiler[:build_type]
    end
    @test_time = 0 if @test_time.nil?
    # handle the case where test is called more than once
    @test_time += (Time.now - start_time)
  end

  def needs_regression_test(compiler)
    (!@config.regression_script.nil? || !@config.regression_repository.nil?) && !ENV['DECENT_CI_SKIP_REGRESSIONS'] && !compiler[:skip_regression]
  end

  def clone_regression_repository
    regression_dir = this_regression_dir
    FileUtils.mkdir_p regression_dir
    return if @config.regression_repository.nil?

    if !@config.regression_commit_sha.nil? && @config.regression_commit_sha != ''
      refspec = @config.regression_commit_sha
    elsif !@config.regression_branch.nil? && @config.regression_branch != ''
      refspec = @config.regression_branch
    else
      $logger.debug('No regression repository checkout info!?!')
      return
    end
    run_scripts(
      @config,
      [
        "cd #{regression_dir} && git init",
        "cd #{regression_dir} && git fetch https://#{@config.token}@github.com/#{@config.regression_repository} #{refspec}",
        "cd #{regression_dir} && git checkout FETCH_HEAD"
      ]
    )
  end

  def next_build
    @test_results = nil
    @test_messages = []
    @build_results = SortedSet.new
    @dateprefix = nil
    @failure = nil
    @build_time = nil
    @test_time = nil
    @test_run = false
    @package_time = nil
    @install_time = nil
    @valgrind_counters_results = nil
    @perf_counters_results = nil
    @file_sizes = nil
    @coverage_lines = 0
    @coverage_total_lines = 0
    @coverage_functions = 0
    @coverage_total_functions = 0
    @coverage_url = nil
    @asset_url = nil
    @acting_as_baseline = false
  end

  def parse_file_sizes(file)
    props = {}

    names = nil

    IO.foreach(file) do |line|
      if names.nil?
        names = line.split
      else
        values = line.split

        values.each_index do |index|
          props[names[index]] = values[index]
        end
      end
    end

    props
  end

  def parse_perf(file)
    props = {}

    IO.foreach(file) do |line|
      values = line.split(',')
      props[values[2]] = values[0].to_i if values.size > (3) && (values[0] != '<not supported>' && values[0] != '')
    end

    props
  end

  def parse_callgrind(build_dir, file)
    object_files = {}
    source_files = {}
    functions = {}
    props = {}

    get_name = lambda do |files, id, name|
      if name.nil? || name == ''
        return_value = files[id]
      elsif id.nil?
        return_value = name
      else
        files[id] = name
        return_value = name
      end
      return_value
    end

    object_file = nil
    source_file = nil
    call_count = nil
    called_object_file = nil
    called_source_file = nil
    called_function_name = nil
    called_functions = {}

    IO.foreach(file) do |line|
      if /^(?<field>[a-z]+): (?<data>.*)/ =~ line
        if field == 'totals'
          totals = data.split
          props['totals'] = totals[0].to_i

          if totals.size == 5
            props['conditional_branches'] = totals[1].to_i
            props['conditional_branches_missses'] = totals[2].to_i
            props['indirect_jumps'] = totals[3].to_i
            props['indirect_jump_misses'] = totals[4].to_i
          end
        else
          props[field] = data
        end
      elsif /^ob=(?<objectfileid>\([0-9]+\))?\s*(?<objectfilename>.*)?/ =~ line
        object_file = get_name.call(object_files, objectfileid, objectfilename)
      elsif /^fl=(?<sourcefileid>\([0-9]+\))?\s*(?<sourcefilename>.*)?/ =~ line
        source_file = get_name.call(source_files, sourcefileid, sourcefilename)
      elsif /^(fe|fi)=(?<sourcefileid>\([0-9]+\))?\s*(?<sourcefilename>.*)?/ =~ line
        get_name.call(source_files, sourcefileid, sourcefilename)
      elsif /^fn=(?<functionid>\([0-9]+\))?\s*(?<functionname>.*)?/ =~ line
        get_name.call(functions, functionid, functionname)
      elsif /^cob=(?<calledobjectfileid>\([0-9]+\))?\s*(?<calledobjectfilename>.*)?/ =~ line
        called_object_file = get_name.call(object_files, calledobjectfileid, calledobjectfilename)
      elsif /^(cfi|cfl)=(?<calledsourcefileid>\([0-9]+\))?\s*(?<calledsourcefilename>.*)?/ =~ line
        called_source_file = get_name.call(source_files, calledsourcefileid, calledsourcefilename)
      elsif /^cfn=(?<calledfunctionid>\([0-9]+\))?\s*(?<calledfunctionname>.*)?/ =~ line
        called_function_name = get_name.call(functions, calledfunctionid, calledfunctionname)
      elsif /^calls=(?<count>[0-9]+)?\s+(?<target_position>[0-9]+)/ =~ line # rubocop:disable Lint/UselessAssignment
        call_count = count
      elsif /^(?<subposition>(((\+|-)?[0-9]+)|\*)) (?<cost>[0-9]+)/ =~ line # rubocop:disable Lint/UselessAssignment
        unless call_count.nil?
          this_object_file = called_object_file.nil? ? object_file : called_object_file
          this_source_file = called_source_file.nil? ? source_file : called_source_file

          called_func_is_nil = called_functions[[this_object_file, this_source_file, called_function_name]].nil?
          called_functions[[this_object_file, this_source_file, called_function_name]] = { 'count' => 0, 'cost' => 0 } if called_func_is_nil

          called_functions[[this_object_file, this_source_file, called_function_name]]['count'] += call_count.to_i
          called_functions[[this_object_file, this_source_file, called_function_name]]['cost'] += cost.to_i

          call_count = nil
          called_object_file = nil
          called_source_file = nil
          called_function_name = nil
        end
        # elsif line == "\n"
      end
    end

    props['object_files'] = []

    object_files.each_value do |this_file|
      abs_path = File.absolute_path(this_file, build_dir)
      next unless abs_path.start_with?(File.absolute_path(build_dir)) && File.exist?(abs_path)

      # is in subdir?
      $logger.info("Path: #{abs_path}  build_dir #{build_dir}")
      props['object_files'] << { 'name' => Pathname.new(abs_path).relative_path_from(Pathname.new(build_dir)).to_s, 'size' => File.size(abs_path) }
    end

    most_expensive = called_functions.sort_by { |_, v| v['cost'] }.reverse.slice(0, 50)
    most_called = called_functions.sort_by { |_, v| v['count'] }.reverse.slice(0, 50)

    important_functions = most_expensive.to_h.merge(most_called.to_h).collect { |k, v| { 'object_file' => k[0], 'source_file' => k[1], 'function_name' => k[2] }.merge(v) }

    props.merge('data' => important_functions)
  end

  def collect_file_sizes(build_dir: File.absolute_path(this_build_dir))
    results = []
    Dir["#{build_dir}/**/size.*"].each do |file|
      file_name = file.sub(/.*size\./, '')
      $logger.info("Parsing #{file}")
      sizes = parse_file_sizes(file)
      sizes['file_name'] = file_name
      results << sizes
    end

    @file_sizes = results
  end

  def collect_perf_results(build_dir: File.absolute_path(this_build_dir))
    results = { 'test_files' => [] }

    Dir["#{build_dir}/**/perf.*"].each do |file|
      perf_counters_test_name = file.sub(/.*perf\./, '')
      $logger.info("Parsing #{file}")
      perf_output = parse_perf(build_dir, file)
      perf_output['test_name'] = perf_counters_test_name
      results['test_files'] << perf_output
    end

    @perf_counters_results = results
  end

  def collect_valgrind_counters_results(build_dir: File.absolute_path(this_build_dir))
    results = { 'object_files' => [], 'test_files' => [] }

    Dir["#{build_dir}/**/callgrind.*"].each do |file|
      valgrind_counters_test_name = file.sub(/.*callgrind\./, '')
      callgrind_output = parse_callgrind(build_dir, file)
      object_files = callgrind_output.delete('object_files')
      $logger.info("Object files: #{object_files}")

      results['object_files'].concat(object_files)
      callgrind_output['test_name'] = valgrind_counters_test_name
      results['test_files'] << callgrind_output
    end

    results['object_files'].uniq!

    @valgrind_counters_results = results
  end

  def post_results(compiler, pending)
    @dateprefix = DateTime.now.utc.strftime('%F') if @dateprefix.nil?

    test_results_data = []

    test_results_passed = 0
    test_results_total = 0
    test_results_warning = 0

    test_results_failure_counts = {}

    @test_results&.each do |t|
      test_results_total += 1
      test_results_passed += 1 if t.passed
      test_results_warning += 1 if t.warning

      category_index = t.name.index('.')
      category_name = 'Uncategorized'
      category_name = t.name.slice(0, category_index) unless category_index.nil?

      failure_type = t.passed ? 'Passed' : t.failure_type

      if test_results_failure_counts[category_name].nil?
        category = {}
        category.default = 0
        test_results_failure_counts[category_name] = category
      end

      test_results_failure_counts[category_name][failure_type] += 1

      test_results_data << t.inspect
    end

    build_errors = 0
    build_warnings = 0
    build_results_data = []

    unless @build_results.nil?
      begin
        @build_results.each do |b|
          build_errors += 1 if b.error?
          build_results_data << b.inspect
        end
      rescue
        build_errors += 1
        build_results_data << { 'message' => 'CI Issue: Error occurred when processing build results on this test' }
        $logger.warn('Error in processing build_results, maybe a duplicate build_result...?')
      end
      build_warnings = @build_results.count - build_errors
    end

    valgrind_counters_total_time = nil
    valgrind_counters_test_count = 0
    valgrind_counters_total_conditional_branches = nil
    valgrind_counters_total_conditional_branch_misses = nil
    valgrind_counters_total_indirect_jumps = nil
    valgrind_counters_total_indirect_jump_misses = nil

    unless @valgrind_counters_results.nil?
      valgrind_counters_total_time = 0
      valgrind_counters_total_conditional_branches = 0
      valgrind_counters_total_conditional_branch_misses = 0
      valgrind_counters_total_indirect_jumps = 0
      valgrind_counters_total_indirect_jump_misses = 0

      @valgrind_counters_results['test_files'].each do |v|
        valgrind_counters_test_count += 1
        valgrind_counters_total_time += v['totals'] unless v['totals'].nil?
        valgrind_counters_total_conditional_branches += v['conditional_branches'] unless v['conditional_branches'].nil?
        valgrind_counters_total_conditional_branch_misses += v['conditional_branch_misses'] unless v['conditional_branch_misses'].nil?
        valgrind_counters_total_indirect_jumps += v['indirect_jumps'] unless v['indirect_jumps'].nil?
        valgrind_counters_total_indirect_jump_misses += v['indirect_jump_misses'] unless v['indirect_jump_misses'].nil?
      end
    end

    perf_counters = {}

    unless @perf_counters_results.nil?
      $logger.debug("perf counters: #{@perf_counters_results}")
      perf_test_count = 0
      @perf_counters_results['test_files'].each do |v|
        perf_test_count += 1
        v.each do |key, value|
          next if value.is_a? String

          new_key = "perf_total_#{key}"

          perf_counters[new_key] = 0 if perf_counters[new_key].nil?

          $logger.debug("Key: '#{new_key}' value: '#{value}'")
          perf_counters[new_key] += value
        end
      end
      perf_counters['perf_test_count'] = perf_test_count
    end

    yaml_data = {
      'title' => build_base_name(compiler),
      'permalink' => "#{build_base_name(compiler)}.html",
      'tags' => 'data',
      'layout' => 'ci_results',
      'date' => DateTime.now.utc.strftime('%F %T'),
      'unhandled_failure' => !@failure.nil?,
      'build_error_count' => build_errors,
      'build_warning_count' => build_warnings,
      'test_count' => test_results_total,
      'test_passed_count' => test_results_passed,
      'repository' => @repository,
      'compiler' => compiler[:name],
      'compiler_version' => compiler[:version],
      'architecture' => compiler[:architecture],
      'os' => @config.os,
      'os_release' => @config.os_release,
      'commit_sha' => @commit_sha,
      'branch_name' => @branch_name,
      'test_run' => !@test_results.nil?,
      'pull_request_issue_id' => @pull_id.to_s,
      'pull_request_base_repository' => @pull_request_base_repository.to_s,
      'pull_request_base_ref' => @pull_request_base_ref.to_s,
      'device_id' => device_id(compiler),
      'pending' => pending,
      'build_time' => @build_time,
      'test_time' => @test_time,
      'install_time' => @install_time,
      'results_repository' => @config.results_repository.to_s,
      'machine_name' => Socket.gethostname.to_s,
      'machine_ip' => Socket.ip_address_list.find { |ai| ai.ipv4? && !ai.ipv4_loopback? }.ip_address.to_s,
      'test_pass_limit' => @config.test_pass_limit,
      'test_warn_limit' => @config.test_warn_limit,
      'coverage_enabled' => compiler[:coverage_enabled],
      'coverage_pass_limit' => compiler[:coverage_pass_limit],
      'coverage_warn_limit' => compiler[:coverage_warn_limit],
      'coverage_lines' => @coverage_lines,
      'coverage_total_lines' => @coverage_total_lines,
      'coverage_functions' => @coverage_functions,
      'coverage_total_functions' => @coverage_total_functions,
      'coverage_url' => @coverage_url,
      'performance_total_time' => valgrind_counters_total_time,
      'performance_test_count' => valgrind_counters_test_count,
      'valgrind_counters_total_time' => valgrind_counters_total_time,
      'valgrind_counters_test_count' => valgrind_counters_test_count,
      'valgrind_counters_total_conditional_branches' => valgrind_counters_total_conditional_branches,
      'valgrind_counters_total_conditional_branch_misses' => valgrind_counters_total_conditional_branch_misses,
      'valgrind_counters_total_indirect_jumps' => valgrind_counters_total_indirect_jumps,
      'valgrind_counters_total_indirect_jump_misses' => valgrind_counters_total_indirect_jump_misses
    }

    yaml_data.merge!(perf_counters)

    json_data = {
      'build_results' => build_results_data,
      'test_results' => test_results_data,
      'failure' => @failure,
      'configuration' => yaml_data,
      'performance_results' => @valgrind_counters_results,
      'perf_performance_results' => @perf_counters_results,
      'file_sizes' => @file_sizes
    }

    json_document =
      <<-YAML
#{yaml_data.to_yaml}
---
#{JSON.pretty_generate(json_data)}
      YAML

    test_failed = false
    if @test_results.nil?
      test_color = 'red'
      test_failed = true
      test_string = 'NA'
    else
      test_percent = if test_results_total.zero?
                       100.0
                     else
                       (test_results_passed.to_f / test_results_total.to_f) * 100.0
                     end

      if test_percent > @config.test_pass_limit
        test_color = 'green'
      elsif test_percent > @config.test_warn_limit
        test_color = 'yellow'
      else
        test_color = 'red'
        test_failed = true
      end
      test_string = "#{test_percent.round(2)}%25"
    end

    test_badge = "<a href='#{@config.results_base_url}/#{build_base_name compiler}.html'>![Test Badge](http://img.shields.io/badge/tests%20passed-#{test_string}-#{test_color}.png)</a>"

    build_failed = false
    if build_errors.positive?
      build_color = 'red'
      build_string = 'failing'
      build_failed = true
    elsif build_warnings.positive?
      build_color = 'yellow'
      build_string = 'warnings'
    else
      build_color = 'green'
      build_string = 'passing'
    end

    build_badge = "<a href='#{@config.results_base_url}/#{build_base_name compiler}.html'>![Build Badge](http://img.shields.io/badge/build%20status-#{build_string}-#{build_color}.png)</a>"

    cov_failed = false
    coverage_badge = ''

    if compiler[:coverage_enabled]
      coverage_percent = if @coverage_total_lines.zero?
                           0
                         else
                           (@coverage_lines.to_f / @coverage_total_lines.to_f) * 100.0
                         end

      if coverage_percent >= compiler[:coverage_pass_limit]
        cov_color = 'green'
      elsif coverage_percent >= compiler[:coverage_warn_limit]
        cov_color = 'yellow'
      else
        cov_color = 'red'
        cov_failed = true
      end
      cov_str = "#{coverage_percent.round(2)}%25"

      coverage_badge = "<a href='#{@config.results_base_url}/#{build_base_name compiler}.html'>![Coverage Badge](http://img.shields.io/badge/coverage%20status-#{cov_str}-#{cov_color}.png)</a>"
    end

    github_status = if pending
                      'pending'
                    elsif build_failed || test_failed || cov_failed || !@failure.nil?
                      'failure'
                    else
                      'success'
                    end

    github_status_message = if pending
                              'Build Pending'
                            elsif build_failed
                              'Build Failed'
                            elsif test_failed
                              "Tests Failed (#{test_results_passed} of #{test_results_total} tests passed, #{test_results_warning} test warnings)"
                            elsif cov_failed
                              'Coverage Too Low'
                            else
                              "OK (#{test_results_passed} of #{test_results_total} tests passed, #{test_results_warning} test warnings)"
                            end

    message_counts = Hash.new(0)
    @test_messages.each { |x| message_counts[x.message] += 1 }

    $logger.debug("Message counts loaded: #{message_counts}")

    message_counts_str = ''
    message_counts.each do |message, count|
      message_counts_str += if count > 1
                              " * #{count} tests had: #{message}\n"
                            else
                              " * 1 test had: #{message}\n"
                            end
    end

    $logger.debug("Message counts string: #{message_counts_str}")

    test_failures_counts_str = ''
    test_results_failure_counts.sort { |a, b| a[0].casecmp(b[0]) }.each do |category, value|
      next if value.size <= 1

      test_failures_counts_str += "\n#{category} Test Summary\n"
      sorted_values = value.sort do |a, b|
        if a[0] == 'Passed'
          -1
        else
          b[0] == 'Passed' ? 1 : a[0].casecmp(b[0])
        end
      end
      sorted_values.each do |failure, count|
        test_failures_counts_str += " * #{failure}: #{count}\n"
      end
    end

    github_document = if @failure.nil?
                        <<-GIT
#{@refspec} (#{@author}) - #{device_id compiler}: #{github_status_message}

#{message_counts_str == '' ? '' : 'Messages:\n'}
#{message_counts_str}
#{test_failures_counts_str == '' ? '' : 'Failures:\n'}
#{test_failures_counts_str}

#{build_badge} #{test_badge} #{coverage_badge}
                        GIT
                      else
                        <<-GIT
<a href='#{@config.results_base_url}/#{build_base_name compiler}.html'>Unhandled Failure</a>
                        GIT
                      end

    if @test_run
      File.open("#{@dateprefix}-#{results_file_name compiler}", 'w+') { |f| f.write(json_document) }
      File.open("#{@dateprefix}-COMMENT-#{results_file_name compiler}", 'w+') { |f| f.write(github_document) }

    else
      begin
        if pending
          $logger.info('Posting pending results file')
          response = github_query(@client) do
            @client.create_contents(
              @config.results_repository,
              "#{@config.results_path}/#{this_branch_folder}/#{@dateprefix}-#{results_file_name compiler}",
              "#{Socket.gethostname}: Commit initial build results file: #{@dateprefix}-#{results_file_name compiler}",
              json_document
            )
          end

          $logger.debug("Results document sha set: #{response.content.sha}")
          @results_document_sha = response.content.sha
        else
          raise 'Error, no prior results document sha set' if @results_document_sha.nil?

          $logger.info("Updating contents with sha #{@results_document_sha}")
          github_query(@client) do
            @client.update_contents(
              @config.results_repository,
              "#{@config.results_path}/#{this_branch_folder}/#{@dateprefix}-#{results_file_name compiler}",
              "#{Socket.gethostname}: Commit final build results file: #{@dateprefix}-#{results_file_name compiler}",
              @results_document_sha,
              json_document
            )
          end
        end
      rescue => e
        $logger.error "Error creating / updating results contents file: #{e}"
        raise e
      end

      if !pending && @config.post_results_comment
        if !@pr_num_to_use_for_comment.nil?
          github_query(@client) { @client.add_comment(@config.repository, @pr_num_to_use_for_comment, github_document) }
        elsif !@pull_id.nil?
          github_query(@client) { @client.add_comment(@config.repository, @pull_id, github_document) }
        elsif !@commit_sha.nil? && @repository == @config.repository
          github_query(@client) { @client.create_commit_comment(@config.repository, @commit_sha, github_document) }
        end
      end

      if !@commit_sha.nil? && @config.post_results_status
        if @pull_request_base_repository.nil?
          github_query(@client) do
            @client.create_status(
              @config.repository,
              @commit_sha,
              github_status,
              :context => device_id(compiler), :target_url => "#{@config.results_base_url}/#{build_base_name compiler}.html", :description => github_status_message
            )
          end
        else
          github_query(@client) do
            @client.create_status(
              @pull_request_base_repository,
              @commit_sha,
              github_status,
              :context => device_id(compiler), :target_url => "#{@config.results_base_url}/#{build_base_name compiler}.html", :description => github_status_message
            )
          end
        end
      end
    end
  end
end
