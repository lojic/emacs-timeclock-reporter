#!/usr/bin/env ruby

require 'optparse'
require 'time'
require 'json'

# This class can create time entries in a file.
#
# Example:
#
# i 2020/09/06 13:25:30 ClientName Project development
# o 2020/09/06 14:11:43
class Timer

  def self.run(args)
    case args[0]
    when "start"
      desc = args[1..-1].join(" ").strip
      if desc == ""
        print_usage
      else
        Timer.new.start(desc)
      end
    when "stop"
      Timer.new.stop
    when "status"
      Timer.new.status
    else
      print_usage
    end
  end

  def self.print_usage
    s = %q{
    USAGE:
    start <description> - start a timer with the given <description>; this will stop any running timer
    stop                - stop the running timer, if any
    status              - displays current timer info
    }
    puts s
  end

  def config
    @config ||= Proc.new {
      JSON.parse(IO.read(File.join(File.dirname(__FILE__), 'timeclock.json')))
    }.call
  end

  def timelog_path
    config()["timelog_path"]
  end

  # starts a timer, stopping current one if it exists
  def start(s)
    stop
    s.gsub!(/"/, "")
    `echo "i #{time_str} #{s}" >> #{timelog_path}`
    true
  end

  # stops a timer if one is running
  def stop
    r = running
    if r
      puts "stopping: #{r[1]}"
      `echo "o #{time_str}" >> #{timelog_path}`
    end
    true
  end

  def status
    r = running
    if r
      puts "#{r[1]} has been running since #{time_str(r[0])}"
    else
      puts "No timer is running"
    end
  end

  # returns the currently running time entry, or nil if none
  #
  # > [ Time, "ClientName Project development" ]
  def running
    last = `tail -n 1 #{timelog_path}`
    if last =~ /\Ai /
      parts = last.strip.split
      time = Time.parse(parts[1..2].join(" "))
      name = parts[3..-1].join(" ")
      [ time, name ]
    else
      nil
    end
  end

  def time_str(t=Time.new)
    t.strftime("%Y/%m/%d %H:%M:%S")
  end
end

if __FILE__ == $0
  Timer.run(ARGV)
end
