require 'rspec'
require_relative '../lib/cmake'
require_relative '../lib/configuration'
require_relative '../lib/resultsprocessor'

class DummyRegressionBuild
  attr_reader :this_build_dir
  attr_reader :commit_sha
  def initialize(build_dir, sha)
    @this_build_dir = build_dir
    @commit_sha = sha
  end
end

class CMakeSpecNamedDummy
  attr_reader :name
  def initialize(this_name)
    @name = this_name
  end
end

describe 'CMake Testing' do
  include CMake
  include Configuration
  include ResultsProcessor

  context 'when calling cmake_build' do
    it 'should try to build a base release package' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      regression_dir = nil
      regression_baseline = nil
      @build_results = SortedSet.new
      args = CMakeBuildArgs.new('Debug', 'thisDeviceIDHere', true,)
      response = cmake_build(compiler,src_dir, build_dir, regression_dir, regression_baseline, args)
      expect(response).to be_truthy
    end
    it 'should try to build a release package with a target_arch key' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      compiler[:target_arch] = "63bit"
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      regression_dir = nil
      regression_baseline = nil
      @build_results = SortedSet.new
      args = CMakeBuildArgs.new('Debug', 'thisDeviceIDHere', true)
      response = cmake_build(compiler,src_dir, build_dir, regression_dir, regression_baseline, args)
      expect(response).to be_truthy
    end
    it 'should try to build a release without ccbin' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      compiler[:cc_bin] = nil
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      regression_dir = nil
      regression_baseline = nil
      @build_results = SortedSet.new
      args = CMakeBuildArgs.new('Debug', 'thisDeviceIDHere', true)
      response = cmake_build(compiler,src_dir, build_dir, regression_dir, regression_baseline, args)
      expect(response).to be_truthy
    end
    it 'should try to build a release with regressions' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      regression_dir = Dir.mktmpdir
      regression_baseline = DummyRegressionBuild.new('/dir/', 'abcd')
      @build_results = SortedSet.new
      args = CMakeBuildArgs.new('Debug', 'thisDeviceIDHere', true)
      response = cmake_build(compiler,src_dir, build_dir, regression_dir, regression_baseline, args)
      expect(response).to be_truthy
    end
  end
  context 'when calling cmake_test' do
    it 'should run a simple set of tests' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(ResultsProcessor).to receive(:process_cmake_results).and_return(true)
      allow_any_instance_of(ResultsProcessor).to receive(:process_ctest_results).and_return([[], []])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      @test_messages = []
      expect(cmake_test(compiler, src_dir, build_dir, 'Debug')).to be_truthy
    end
    it 'should run a simple set of tests and concatenate test_results' do
      allow_any_instance_of(Runners).to receive(:run_scripts).and_return(['stdoutmsg', 'stderrmsg', 0])
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([CMakeSpecNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(ResultsProcessor).to receive(:process_cmake_results).and_return(true)
      allow_any_instance_of(ResultsProcessor).to receive(:process_ctest_results).and_return([[], []])
      @client = Octokit::Client.new(:access_token => 'abc')
      @config = load_configuration('spec/resources', 'abc', false)
      compiler = @config.compilers.first
      src_dir = Dir.mktmpdir
      build_dir = File.join(src_dir, 'build')
      @test_results = []
      @test_messages = []
      expect(cmake_test(compiler, src_dir, build_dir, 'Debug')).to be_truthy
    end
  end
end
