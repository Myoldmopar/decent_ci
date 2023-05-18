require 'coveralls'
require 'logger'
require 'simplecov'
require 'simplecov-console'
require 'simplecov-lcov'

# load up the coverage stuff so the shims are in place for loading actual source afterwards
Coveralls.wear!
SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new(
    [
        SimpleCov::Formatter::LcovFormatter,
        SimpleCov::Formatter::HTMLFormatter
    ]
)
SimpleCov.start do
  add_filter "lib/processor.rb"  # this function is heavily cross platform and distribution and we won't get good coverage
end

# SimpleCov::Formatter::LcovFormatter.config do |c|
#   c.report_with_single_file = true
#   c.single_report_path = 'coverage/lcov.info'
# end

# use this to easily run a single test
RSpec.configure do |config|
  #config.filter_run_when_matching :focus
end

# set up a logger global variable for unit testing, but set it to only show fatals
$logger = Logger.new "decent_ci_testing.log", 1
$logger.level = Logger::FATAL
