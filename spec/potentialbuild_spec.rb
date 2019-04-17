require 'rspec'
require_relative '../lib/potentialbuild'
require_relative '../lib/resultsprocessor'

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

describe 'PotentialBuild Testing', :focus do
  include ResultsProcessor
  context 'when doing simple construction' do
    it 'should succeed at construction' do
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([PotentialBuildNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(Octokit::Client).to receive(:repo).and_return(PotentialBuildDummyRepo.new)
      client = Octokit::Client.new(:access_token => 'abc')
      token = 'abc'
      repo = 'spec/resources'
      tag_name = ''
      commit_sha = 'abc123'
      branch_name = 'feature'
      author = 'octokat'
      release_url = nil
      release_assets = nil
      pull_id = 32
      pr_base_repo = nil
      pr_base_ref = nil
      p = PotentialBuild.new(client, token, repo, tag_name, commit_sha, branch_name, author, release_url, release_assets, pull_id, pr_base_repo, pr_base_ref)
    end
  end
  context 'when calling needs_release_package' do
    it 'should base it on the analyze only flag' do
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([PotentialBuildNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(Octokit::Client).to receive(:repo).and_return(PotentialBuildDummyRepo.new)
      client = Octokit::Client.new(:access_token => 'abc')
      p = PotentialBuild.new(client, '', 'spec/resources', '', '', '', '', '', '', 0, '', '')
      expect(p.needs_release_package({:analyze_only => true})).to be_falsey
      expect(p.needs_release_package({})).to be_truthy # defaults to true if no key
      expect(p.needs_release_package({:analyze_only => false})).to be_truthy
    end
  end
  context 'when calling checkout' do
    before do
      expect_any_instance_of(ResultsProcessor).to receive(:run_scripts).with(anything, instance_of(Array)).and_return(['stdout', 'stderr', 0])
    end
    it 'should succeed' do
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([PotentialBuildNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(Octokit::Client).to receive(:repo).and_return(PotentialBuildDummyRepo.new)
      client = Octokit::Client.new(:access_token => 'abc')
      p = PotentialBuild.new(client, '', 'spec/resources', '', '', '', '', '', '', 0, '', '')
      src_dir = Dir.mktmpdir
      expect(p.checkout(src_dir)).to be_truthy
    end
  end
  context 'when calling small attribute functions' do
    before do
      allow_any_instance_of(Octokit::Client).to receive(:content).and_return([PotentialBuildNamedDummy.new('.decent_ci.yaml')])
      allow_any_instance_of(Octokit::Client).to receive(:repo).and_return(PotentialBuildDummyRepo.new)
      client = Octokit::Client.new(:access_token => 'abc')
      @p = PotentialBuild.new(client, '', 'spec/resources', '', '', '', '', '', '', 0, '', '')
    end
    it 'get_src_dir should make a selection based on baseline mode' do
      expect(@p.this_src_dir).to include 'branch'
      @p.set_as_baseline
      expect(@p.this_src_dir).to include 'baseline'
    end
    it 'device_tag should return a string with optional debug tag' do
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'Release'})).not_to include 'Release'
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'Debug'})).to include 'Debug'
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'RelWithDebInfo'})).to include 'RelWithDebInfo'
    end
    it 'device_tag should return a string with optional debug tag' do
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'Release'})).not_to include 'Release'
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'Debug'})).to include 'Debug'
      expect(@p.device_tag({:build_tag => 'hello', :build_type => 'RelWithDebInfo'})).to include 'RelWithDebInfo'
    end
    it 'descriptive_string should just return a string' do
      expect(@p.descriptive_string).to be_instance_of String
    end
    it 'boolean flag functions should return booleans' do
      expect(@p.release?).to be_in([true, false])
      expect(@p.pull_request?).to be_in([true, false])
    end
  end
end

