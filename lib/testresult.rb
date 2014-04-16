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

class TestResult
  def initialize(name, status, time, output, parsed_errors)
    @name = name
    @status = status
    @time = time
    @output = output
    @parsed_errors = parsed_errors
  end

  def passed
    return @status == "passed"
  end

  def inspect
    parsed_errors_array = []

    if !@parsed_errors.nil?
      @parsed_errors.each { |e|
        parsed_errors_array << e.inspect
      }
    end

    hash = {:name => @name,
      :status => @status,
      :time => @time,
      :output => @output,
      :parsed_errors => parsed_errors_array
      }
    return hash
  end

end


