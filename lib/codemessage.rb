# frozen_string_literal: true

# warnings and errors from code compilation
class CodeMessage
  include Comparable
  attr_reader :filename, :linenumber, :colnumber, :messagetype
  attr_accessor :message

  def initialize(filename, linenumber, colnumber, messagetype, message)
    @filename = filename
    @linenumber = linenumber
    @colnumber = colnumber
    @messagetype = messagetype
    @message = message
  end

  # Checks if this instance constitutes a warning
  #
  # @return [Boolean] true if the code message is a warning, false otherwise
  def warning?
    @messagetype =~ /.*warn.*/i
  end

  def error?
    @messagetype =~ /.*err.*/i
  end

  def inspect
    hash = {}
    instance_variables.each { |var| hash[var.to_s.delete('@')] = instance_variable_get(var) }
    hash
  end

  def hash
    inspect.hash
  end

  # Checks if two CodeMessage objects are equal
  #
  # @param other [CodeMessage] a second CodeMessage instance to compare against self
  # @return [Boolean] true if the objects are data-equal, false otherwise
  def eql?(other)
    (self <=> other).zero?
  end

  # Checks if two CodeMessage objects are different
  #
  # @param other [CodeMessage] a second CodeMessage instance to compare against self
  # @return [Boolean] false if the objects are data-equal, true otherwise
  def <=>(other)
    f = @filename <=> other.filename
    l = @linenumber.to_i <=> other.linenumber.to_i
    c = @colnumber.to_i <=> other.colnumber.to_i
    mt = @messagetype <=> other.messagetype
    m = @message[0..10] <=> other.message[0..10]

    if f != 0
      f
    elsif l != 0
      l
    elsif c != 0
      c
    elsif mt != 0
      mt
    else
      m
    end
  end
end
