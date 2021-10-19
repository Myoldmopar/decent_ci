#!/usr/bin/env ruby
# encoding: UTF-8 

require 'rspec'
require 'fileutils'
require 'logger'
require 'octokit'
require_relative 'lib/cppcheck'
require_relative 'lib/custom_check'
require_relative 'lib/potentialbuild'
require_relative 'lib/resultsprocessor'

class PotentialBuildDummyRepo
  def name
    'repo_name'
  end
end

class PotentialBuildNamedDummy
  attr_reader :name
  def initialize(this_name)
    @name = this_name
  end
end

$logger = Logger.new "decent_ci.log", 10

#allow_any_instance_of(Octokit::Client).to receive(:content).and_return([PotentialBuildNamedDummy.new('.decent_ci.yaml')])
#allow_any_instance_of(Octokit::Client).to receive(:repo).and_return(PotentialBuildDummyRepo.new)


class MockClient
  def initialize()
  end

  def content(a,b)
    return [PotentialBuildNamedDummy.new('.decent_ci.yaml')]
  end

  def repo(a)
    return PotentialBuildDummyRepo.new
  end

end

client = MockClient.new()
p = PotentialBuild.new(client, '', 'spec/resources', '', '', '', '', '', '', 0, '', '')

p.collect_file_sizes(build_dir:ARGV[0])
p.collect_perf_results(build_dir:ARGV[0])
p.collect_valgrind_counters_results(build_dir:ARGV[0])
p.test_run = true
compiler = { :num_parallel_builds => 2, :compiler_extra_flags => "hello", :cppcheck_bin => "/usr/bin/cppcheck" }

p.post_results(compiler, false)


