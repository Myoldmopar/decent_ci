# frozen_string_literal: true

require_relative 'runners'

# simple data class for passing args into cmake_build
class CMakeBuildArgs
  attr_reader :build_type, :this_device_id

  def initialize(build_type, device_id)
    @build_type = build_type
    @this_device_id = device_id
  end
end

# contains functions necessary for working with the 'cmake' engine
module CMake
  include Runners

  def cmake_build(compiler, src_dir, build_dir, regression_dir, regression_baseline, cmake_build_args)
    FileUtils.mkdir_p build_dir

    cmake_flags = "#{compiler[:cmake_extra_flags]} -DDEVICE_ID:STRING=\"#{cmake_build_args.this_device_id}\""

    compiler_extra_flags = compiler[:compiler_extra_flags]
    compiler_extra_flags = '' if compiler_extra_flags.nil?

    if compiler[:cc_bin].nil?
      env = {
        'CXXFLAGS' => "/FC #{compiler_extra_flags}",
        'CFLAGS' => "/FC #{compiler_extra_flags}",
        'CCACHE_BASEDIR' => build_dir,
        'CCACHE_UNIFY' => 'true',
        'CCACHE_SLOPPINESS' => 'include_file_mtime'
      }
    else
      cmake_flags = "-DCMAKE_C_COMPILER:PATH=\"#{compiler[:cc_bin]}\" -DCMAKE_CXX_COMPILER:PATH=\"#{compiler[:cxx_bin]}\" #{cmake_flags}"
      env = {
        'CXXFLAGS' => compiler_extra_flags.to_s,
        'CFLAGS' => compiler_extra_flags.to_s,
        'CCACHE_BASEDIR' => build_dir,
        'CCACHE_UNIFY' => 'true',
        'CCACHE_SLOPPINESS' => 'include_file_mtime',
        'CC' => compiler[:cc_bin],
        'CXX' => compiler[:cxx_bin]
      }
    end

    env['PATH'] = cmake_remove_git_from_path(ENV['PATH'])

    if regression_baseline.nil?
      env['REGRESSION_BASELINE'] = ' '
      env['REGRESSION_DIR'] = ' '
      env['REGRESSION_BASELINE_SHA'] = ' '
      env['COMMIT_SHA'] = ' '
    else
      env['REGRESSION_BASELINE'] = File.expand_path(regression_baseline.this_build_dir)
      env['REGRESSION_DIR'] = File.expand_path(regression_dir)
      env['REGRESSION_BASELINE_SHA'] = regression_baseline.commit_sha
      env['COMMIT_SHA'] = @commit_sha && @commit_sha != '' ? @commit_sha : @tag_name
    end

    env['GITHUB_TOKEN'] = ENV['GITHUB_TOKEN']

    if compiler[:name] == 'Visual Studio'
      # :nocov: Not testing windows right now
      _, err, result = run_scripts(
        @config,
        ["cd #{build_dir} && #{@config.cmake_bin} ../ #{cmake_flags}  -DCMAKE_BUILD_TYPE:STRING=#{cmake_build_args.build_type} -G \"#{compiler[:build_generator]}\" -A #{compiler[:target_arch]}"], env
      )
      # :nocov:
    else
      _, err, result = run_scripts(
        @config,
        ["cd #{build_dir} && #{@config.cmake_bin} ../ #{cmake_flags}  -DCMAKE_BUILD_TYPE:STRING=#{cmake_build_args.build_type} -G \"#{compiler[:build_generator]}\""], env
      )
    end

    cmake_result = process_cmake_results(src_dir, build_dir, err, result)

    return false unless cmake_result

    $logger.info('Configure step completed, beginning build step')

    build_switches = if @config.os == 'Windows'
                       ''
                     else
                       # :nocov: Not covering windows
                       "-j#{compiler[:num_parallel_builds]}"
                       # :nocov:
                     end

    out, err, result = run_scripts(
      @config,
      ["cd #{build_dir} && #{@config.cmake_bin} --build . --config #{cmake_build_args.build_type} --use-stderr -- #{build_switches}"], env
    )

    msvc_success = process_msvc_results(src_dir, build_dir, out, result)
    gcc_success = process_gcc_results(src_dir, build_dir, err, result)
    process_cmake_results(src_dir, build_dir, err, result)
    process_python_results(src_dir, build_dir, out, err, result)
    msvc_success && gcc_success
  end

  def cmake_remove_git_from_path(old_path)
    # The point is to remove the git provided sh.exe from the path so that it does
    # not conflict with other operations
    if @config.os == 'Windows'
      # :nocov: Not covering Windows
      paths = old_path.split(';')
      paths.delete_if { |p| p =~ /Git/ }
      return paths.join(';')
      # :nocov:
    end

    old_path
  end

  def cmake_test(compiler, src_dir, build_dir, build_type)
    test_dirs = [''] # always start with the root build directory

    ctest_filter = compiler[:ctest_filter]
    ctest_filter = '' if ctest_filter.nil?

    test_dirs.each do |test_dir|
      $logger.info("Running tests in dir: '#{build_dir}/#{test_dir}'")
      env = { 'PATH' => cmake_remove_git_from_path(ENV['PATH']) }
      _, test_stderr, test_result = run_scripts(
        @config,
        ["cd #{build_dir}/#{test_dir} && #{@config.ctest_bin} -j #{compiler[:num_parallel_builds]} --timeout 4800 --no-compress-output -D ExperimentalTest -C #{build_type} #{ctest_filter}"],
        env
      )
      test_results, test_messages = process_ctest_results src_dir, build_dir, "#{build_dir}/#{test_dir}"

      if @test_results.nil?
        @test_results = test_results
      else
        @test_results.concat(test_results) unless test_results.nil?
      end

      @test_messages.concat(test_messages)

      # may as well see if there are some cmake results to pick up here
      process_cmake_results(src_dir, build_dir, test_stderr, test_result)
    end
  end
end
