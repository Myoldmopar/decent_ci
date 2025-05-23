# frozen_string_literal: true

require_relative 'decent_exceptions'
require_relative 'processor'

# tools for loading and parsing of yaml config files
# and filling in the details.  A minimal merged config
# should at least define the compiler.  Individual setup*
# functions in this module will raise Exceptions for
# invalid conditions, while blanks will be applied if it
# is a suitable default.
module Configuration
  # Cross-platform way of finding an executable in the $PATH.
  #
  #   which('ruby') #=> /usr/bin/ruby
  def which(cmd, extra_paths = nil)
    exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
    path_array = ENV['PATH'].split(File::PATH_SEPARATOR)
    path_array.concat(extra_paths) unless extra_paths.nil?

    path_array.each do |path|
      exts.each do |ext|
        exe = File.join(path, "#{cmd}#{ext}")
        return Pathname.new(exe).cleanpath.to_s if File.executable? exe
      end
    end
    nil
  end

  def load_yaml(name, this_location, this_ref)
    return nil if this_location.nil? || name.nil?

    begin
      content = @client.content(this_location, :path => name, :ref => this_ref)
      contents = content.content
      return_value = YAML.load(Base64.decode64(contents.to_s))
    rescue Psych::SyntaxError, SyntaxError => e
      raise "#{e.message} while parsing #{name}@#{this_ref}"
    rescue => e
      $logger.debug("Unable to load yaml file from repository: #{this_location}/#{name}@#{this_ref} error: #{e}")
      path = File.expand_path(name, this_location)
      $logger.debug("Attempting to load yaml config file: #{path}")
      if File.exist?(path)
        return_value = YAML.load_file(path)
      else
        $logger.debug("yaml file does not exist: #{path}")
        return_value = nil
      end
    end
    return_value
  end

  def symbolize(obj)
    case obj
    when Hash
      obj.reduce({}) do |memo, (k, v)|
        memo.tap { |m| m[k.to_sym] = symbolize(v) }
      end
    when Array
      obj.reduce([]) do |memo, v|
        memo << symbolize(v)
        memo
      end
    else
      obj
    end
  end

  # :nocov: Not doing any testing on Windows right now
  def establish_windows_characteristics
    os_version = 'Windows'
    ver_string = `cmd /c ver`.strip
    /.* \[Version (?<ver_major>[0-9]+)\.(?<ver_minor>[0-9]+)\..*\]/ =~ ver_string
    os_release = nil
    os_release = '10' if ver_major.to_i == 10
    os_release = "Unknown-#{ver_major}.#{ver_minor}" if os_release.nil?
    [nil, os_version, os_release]
  end
  # :nocov:

  def establish_os_characteristics
    # if RUBY_VERSION[0..2].to_f < 2.4
    # we must not use match?, it isn't available...
    # for now I'll just try to use without ? everywhere, we'll see
    # end
    case RUBY_PLATFORM
    when /darwin/i
      os_distribution = nil
      os_version = 'MacOS'
      ver_string = `uname -v`.strip
      /.* Version (?<ver_major>[0-9]+)\.([0-9]+)\.([0-9]+).*:.*/ =~ ver_string
      # the darwin version number - 4 = the point release of macosx
      os_release = "10.#{ver_major.to_i - 4}"
    when /linux/i
      os_distribution = `lsb_release -is`.strip
      os_version = 'Linux'
      os_release = "#{`lsb_release -is`.strip}-#{`lsb_release -rs`.strip}"
    else
      # :nocov: Not testing on windows right now
      os_distribution, os_version, os_release = establish_windows_characteristics
      # :nocov:
    end
    [os_distribution, os_version, os_release]
  end

  def get_all_yaml_names(os_version, os_release, os_distribution)
    yaml_base_name = '.decent_ci'
    yaml_name = "#{yaml_base_name}.yaml"
    yaml_os_name = "#{yaml_base_name}-#{os_version}.yaml"
    yaml_os_release_name = "#{yaml_base_name}-#{os_version}-#{os_release}.yaml"
    yaml_os_distribution_name = nil
    yaml_os_distribution_name = "#{yaml_base_name}-#{os_version}-#{os_distribution}.yaml" unless os_distribution.nil?
    [yaml_name, yaml_os_name, yaml_os_release_name, yaml_os_distribution_name]
  end

  def establish_base_configuration(os_version, os_release)
    cmake_paths = ['C:\\Program Files\\CMake\\bin',
                   'C:\\Program Files (x86)\\CMake\\bin',
                   'C:\\Program Files\\CMake 3.0\\bin',
                   'C:\\Program Files (x86)\\CMake 3.0\\bin',
                   'C:\\Program Files\\CMake 2.8\\bin',
                   'C:\\Program Files (x86)\\CMake 2.8\\bin',
                   'C:\\ProgramData\\chocolatey\\bin']

    {
      :os => os_version,
      :os_release => os_release,
      :engine => 'cmake',
      :post_results_comment => true,
      :post_results_status => true,
      :cmake_bin => "\"#{which('cmake', cmake_paths)}\"",
      :ctest_bin => "\"#{which('ctest', cmake_paths)}\""
    }
  end

  # returns a list of yaml-based configuration data sets
  # they may be nil values if the yaml config couldn't be found by name
  def find_valid_yaml_files(all_yaml_names, location, ref, fileset)
    valid_yaml_configs = []
    all_yaml_names.each do |yaml|
      attempted_yaml = load_yaml(yaml, location, ref)
      valid_yaml_configs << attempted_yaml if fileset.include?(yaml)
    end
    valid_yaml_configs
  end

  def setup_compiler_architecture(compiler)
    return compiler[:architecture] unless compiler[:architecture].nil?

    if compiler[:name] == 'Visual Studio'
      'i386'
    else
      RbConfig::CONFIG['host_cpu']
    end
  end

  def setup_compiler_version(compiler)
    return compiler[:version] unless compiler[:version].nil?

    case compiler[:name]
    when 'Visual Studio'
      raise 'Version number for visual studio must be provided'
    when 'clang'
      /.*clang version (?<version>([0-9]+\.?)+).*/ =~ `clang --version`
      version
    when 'gcc'
      `gcc -dumpversion`
    else
      raise 'Invalid compiler specified, must be one of clang, gcc, or a variation on "Visual Studio VV YYYY"'
    end
  end

  def setup_compiler_description(compiler)
    raise 'Compiler name not specified, must at least specify name' if compiler[:name].nil?

    description = compiler[:name].gsub(/\s+/, '')
    description = "#{description}-#{compiler[:version]}" unless compiler[:version].nil?
    description
  end

  def setup_compiler_extra_flags(compiler, is_release)
    if is_release && !compiler[:cmake_extra_flags_release].nil?
      compiler[:cmake_extra_flags_release]
    elsif compiler[:cmake_extra_flags].nil?
      ''
    else
      compiler[:cmake_extra_flags]
    end
  end

  def setup_compiler_num_processors(compiler)
    return compiler[:num_parallel_builds] unless compiler[:num_parallel_builds].nil?

    num_processors = processor_count
    num_processors -= 1 if num_processors > 2
    num_processors
  end

  def setup_compiler_build_generator(compiler)
    return compiler[:build_generator] unless compiler[:build_generator].nil?

    if compiler[:name].match(/.*Visual Studio.*/i)
      'Visual Studio 16 2019'
    else
      'Unix Makefiles'
    end
  end

  def setup_compiler_target_arch(compiler)
    if compiler[:name].match(/.*Visual Studio.*/i)
      # Visual Studio 2019+ generator behaves slightly different, need to add -A
      return 'x64' if !compiler[:architecture].nil? && compiler[:architecture].match(/.*64.*/)

      return 'Win32'
    end
    compiler[:architecture]
  end

  def _setup_cc_and_cxx(compiler, cc_name, cxx_name)
    potential_name = which("#{cc_name}-#{compiler[:version]}")
    if potential_name.nil?
      cc_bin = which(cc_name)
      cxx_bin = which(cxx_name)
    else
      cc_bin = potential_name
      cxx_bin = which("#{cxx_name}-#{compiler[:version]}")
    end

    if cc_bin.nil? || cxx_bin.nil? || (`#{cc_bin} --version` !~ /.*#{compiler[:version]}/) || (`#{cxx_bin} --version` !~ /.*#{compiler[:version]}/)
      raise CannotMatchCompiler, "Unable to find appropriate compiler for: #{compiler[:name]} version #{compiler[:version]}"
    end

    [cc_bin, cxx_bin]
  end

  def setup_gcc_style_cc_and_cxx(compiler)
    return [compiler[:cc_bin], compiler[:cxx_bin]] unless compiler[:cc_bin].nil? || compiler[:cxx_bin].nil?

    return [nil, nil] if compiler[:name].nil? || !%w[clang gcc].include?(compiler[:name])

    if compiler[:name] == 'clang'
      cc_bin, cxx_bin = _setup_cc_and_cxx(compiler, 'clang', 'clang++')
    else # gcc
      cc_bin, cxx_bin = _setup_cc_and_cxx(compiler, 'gcc', 'g++')
    end

    [cc_bin, cxx_bin]
  end

  def setup_single_compiler(compiler, is_release)
    compiler[:architecture] = setup_compiler_architecture(compiler)
    compiler[:version] = setup_compiler_version(compiler)
    compiler[:cc_bin], compiler[:cxx_bin] = setup_gcc_style_cc_and_cxx(compiler)
    compiler[:analyze_only] = false
    compiler[:release_only] = false if compiler[:release_only].nil?
    compiler[:skip_packaging] = (compiler[:skip_packaging] =~ /true/i) || compiler[:skip_packaging] if compiler[:skip_packaging].nil?
    compiler[:description] = setup_compiler_description(compiler)
    compiler[:build_type] = 'Release' if compiler[:build_type].nil? || compiler[:build_type] == ''
    compiler[:build_generator] = setup_compiler_build_generator(compiler)
    compiler[:target_arch] = setup_compiler_target_arch(compiler)
    compiler[:skip_regression] = false if compiler[:skip_regression].nil?
    compiler[:collect_performance_results] = false if compiler[:collect_performance_results].nil?
    compiler[:ctest_filter] = '' if compiler[:ctest_filter].nil?
    compiler[:coverage_base_dir] = '' if compiler[:coverage_base_dir].nil?
    compiler[:coverage_enabled] = false if compiler[:coverage_enabled].nil?
    compiler[:coverage_pass_limit] = 90 if compiler[:coverage_pass_limit].nil?
    compiler[:coverage_warn_limit] = 75 if compiler[:coverage_warn_limit].nil?
    compiler[:cmake_extra_flags] = setup_compiler_extra_flags(compiler, is_release)
    compiler[:num_parallel_builds] = setup_compiler_num_processors(compiler)

    raise CannotMatchCompiler, 'Decent CI currently only deployed with Visual Studio version 16 (2019)' if compiler[:name] =~ /.*Visual Studio.*/i && compiler[:version] != 16

    compiler
  end

  def load_configuration(location, ref, is_release)
    # first get a list of all decent_ci files found at the root of the repo, and raise if none were found
    fileset = Set.new
    @client.content(location, :path => '.', :ref => ref).each do |path|
      fileset << path.name if path.name =~ /\.decent_ci.*/
    end
    $logger.debug("For ref #{ref} .decent_ci files located: #{fileset.to_a}")
    raise NoDecentCIFiles, 'No .decent_ci input files' if fileset.empty?

    # then try to form up a final merged configuration of all the yaml files found and symbolize it, raise if no compilers found
    os_distribution, os_version, os_release = establish_os_characteristics
    yaml_names = get_all_yaml_names(os_version, os_release, os_distribution)
    valid_yamls = find_valid_yaml_files(yaml_names, location, ref, fileset)
    result_yaml = establish_base_configuration(os_version, os_release)
    valid_yamls.each do |yaml|
      result_yaml.merge!(yaml) unless yaml.nil?
    end
    result_yaml = symbolize(result_yaml)
    $logger.debug("Final merged configuration: #{result_yaml}")

    # create a configuration struct from the yaml data and escape early if there aren't any compilers
    configuration = OpenStruct.new(result_yaml)
    raise 'No compilers defined' if configuration.compilers.nil?

    # loop over all compilers and fill in defaults and check for erroneous conditions
    configuration.compilers.each do |compiler|
      $logger.debug("Working on compiler: #{compiler[:name]}")
      setup_single_compiler(compiler, is_release)
    end

    # do final touchups on the configuration
    configuration.aging_pull_requests_notification = true if configuration.aging_pull_requests_notification.nil?
    configuration.aging_pull_requests_numdays = 7 if configuration.aging_pull_requests_numdays.nil?

    configuration
  end
end
