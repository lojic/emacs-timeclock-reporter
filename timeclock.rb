#!/usr/bin/env ruby

# Copyright (C) 2007-2014 by Brian J. Adkins

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# = Name
# timeclock.rb
#
# = Synopsis
# Process an emacs time log file.
#
# = Usage
# ruby timeclock.rb [OPTION] [regex] < emacs_timelog
#   [ -b | --begin-date DATE ]
#   [ -e | --end-date DATE ]
#   [ -g | --group LEVELS ]
#   [ -h | --help ]
#   [ -s | --statistics ]
#   [ -t | --today-only ]
#   [ -v | --invert-match ]
#   [ -w | --week [DATE] ]
#
# = Help
# help::
#   Print this information
# regex::
#   select only records matching the regex
# today-only::
#   Only process records for today
# begin-date::
#   Specify the beginning date, and optionally time, for which earlier entries
#   will be excluded. If the time is omitted, 0:00:00 is assumed.
# end-date::
#   Specify the ending date, and optionally time, for which later entries
#   will be excluded. If the time is omitted, 0:00:00 is assumed.
# statistics::
#   Print daily and total hour amounts
# invert-match::
#   Invert the sense of matching the regex to only select non-matching entries
# group:
#   Specify the number of grouping levels for computing statistics. A group
#   levels > 1 implies --statistics
# week:
#   Report on weekly statistics.
#     Implies:
#       --begin-date
#       --end-date
#       --statistics
#       --group 1
#
# = Authors
# Brian Adkins
# Tom Davies
#
# = Date
# 03/05/2008

# Config file is of the form:
# {
#   "day_starts"     : "8:00",
#   "work_days"      : 6,
#   "work_hours"     : 7,
#   "timelog_path"   : "/path_to/emacs/timelog"
# }
#
# To have the script automatically compute the "day_starts" value from
# the first entry of the day in the timelog, use "auto" instead of a
# time.

require 'optparse'
require 'date'
require 'json'

TimeEntry = Struct.new(:is_start, :time, :description)
TimePair  = Struct.new(:start, :end)
TimeDay   = Struct.new(:mon, :day, :year, :pairs, :group_hours)

module TimeClock

  def self.run args, config
    options, rest = TimeClock.parse_arguments(args)

    entries = TimeClock.parse_time_entries(config['timelog_path'],
                                           options[:begin_date],
                                           options[:end_date],
                                           rest[0],
                                           options[:invert_match])

    # Group into days
    days = TimeClock.parse_days(entries)

    # Print a report and accumulate group stats
    group_stats = TimeClock.print_report(days, options[:statistics], options[:group_levels])

    if options[:statistics]
      TimeClock.print_statistics(config, days, options[:today],
        date_range_display(options[:begin_date], options[:end_date] - 1))
    end
  end

  def self.beginning_of_week d
    d.monday? ? d : beginning_of_week(d-1)
  end

  #------------------------------------------------------------------------
  # Compute a grouping key from the time description based on the
  # specified levels. For example, if the description was the following:
  # Lojic research Ruby
  # Then the group key would be the following based on the specified levels:
  # 0: ""
  # 1: "Lojic"
  # 2: "Lojic research"
  # 3: "Lojic research Ruby"
  #------------------------------------------------------------------------
  def self.compute_group_key description, levels, sep = ' '
    if levels < 1
      ''
    else
      tokens = description.split(sep)
      if tokens.length > levels
        tokens[0, levels].join(sep)
      else
        description
      end
    end
  end

  def self.default_options
    {
      :begin_date   => DateTime.parse("2000-01-01", true),
      :end_date     => DateTime.parse("2050-01-01", true),
      :group_levels => 0,
      :invert_match => false,
      :statistics   => false,
      :today        => false,
      :week_date    => beginning_of_week(DateTime.parse(Date.today.to_s)),
    }
  end

  #------------------------------------------------------------------------
  # Compute the elapsed time of a TimePair
  # (assumes pair is within same day)
  #------------------------------------------------------------------------
  def self.elapsed pair
    (pair.end.time - pair.start.time) * 24.0
  end

  #------------------------------------------------------------------------
  # Return a pair [line, lines_read] where line == nil if eof encountered
  #------------------------------------------------------------------------
  def self.get_line file
    lines_read = 0

    while line = file.gets
      lines_read += 1
      line.strip!
      break unless line.length < 1
    end

    return [line, lines_read]
  end

  #------------------------------------------------------------------------
  # Return a 2 element list of the TimePair's start/end times converted to hours
  # e.g. [ 9.7, 15.4 ]
  # (assumes pair within same day)
  #------------------------------------------------------------------------
  def self.hours_interval pair
    [pair.start.time, pair.end.time].map {|t| t.hour + t.min / 60.0 + t.sec / 3600.0 }
  end

  def self.min a, b
    a < b ? a : b
  end

  def self.parse_arguments args
    explicit_group_levels = false
    options = default_options

    opts = OptionParser.new
    opts.on("-h", "--help")            { puts opts; exit }
    opts.on("-b", "--begin-date DATE") {|d| options[:begin_date] = DateTime.parse(d, true) }
    opts.on("-e", "--end-date DATE")   {|d| options[:end_date]   = DateTime.parse(d, true) }
    opts.on("-s", "--statistics")      { options[:statistics]    = true              }
    opts.on("-v", "--invert-match")    { options[:invert_match]  = true              }
    opts.on("-t", "--today-only") do
      options[:begin_date] = DateTime.parse(Time.now.strftime("%Y-%m-%d"))
      options[:end_date] = options[:begin_date] + 1
      options[:today] = true
    end
    opts.on("-g", "--group LEVELS") do |levels|
      explicit_group_levels = true
      options[:group_levels] = levels.to_i
      options[:statistics] = true if options[:group_levels] > 0
    end
    opts.on("-w", "--week [m:n]") do |arg|
      # For the current week:             -w 0:0 | -w 0 | -w
      # For last week only:               -w 1 | -w 1:1
      # For two weeks ago only:           -w 2 | -w 2:2
      # For the last two weeks:           -w 1:0
      # For the last three weeks:         -w 2:0
      # For last week plus two weeks ago: -w 2:1
      lst = (arg || '').split(':')
      m = (lst[0] ? lst[0].to_i : 0)
      n = (lst[1] ? lst[1].to_i : m)
      options[:begin_date] = options[:week_date] - (7 * m)
      options[:end_date]   = options[:week_date] - (7 * n) + 7
      options[:week_stats] = true

      unless explicit_group_levels
        options[:statistics]   = true
        options[:group_levels] = 1
      end
    end

    rest = opts.parse(args) rescue RDoc::usage('usage')
    [ options, rest ]
  end

  #------------------------------------------------------------------------
  # Parse a pair of in/out entries and return a list of pairs or nil.
  # This function will split a single pair into two pairs if it
  # spans a midnight.
  #------------------------------------------------------------------------
  def self.parse_complete_pair i, o, begin_date, end_date
    case
      # Case 1: out < begin_date => skip
    when o.time < begin_date
      return nil

      # Case 2: in > end_date => skip
    when i.time > end_date
      return nil

      # Case 3: entry intersects [begin_date, end_date]
    else
      pair = TimePair.new(i,o)
      if i.time >= begin_date && o.time < end_date
        # all of pair is within filtered span
        if i.time.day == o.time.day
          return [ pair ]
        else
          return split_time_pair(pair)
        end
      elsif i.time < begin_date
        # split and append second portion
        return [ split_time_pair(pair)[1] ]
      elsif o.time >= end_date
        # split and append first portion
        return [ split_time_pair(pair)[0] ]
      else
        raise 'this should not happen :)'
      end
    end
  end

  #------------------------------------------------------------------------
  # Aggregate a list of TimePair objects into days
  #------------------------------------------------------------------------
  def self.parse_days pairs
    current_day = { :mon => 1, :day => 1, :year => 1970 }
    days = []
    pairs.each do |pair|
      t = pair.start.time
      day = { :mon => t.mon, :day => t.day, :year => t.year }

      if day == current_day
        days.last[:pairs] << pair
      else
        days << TimeDay.new(day[:mon], day[:day], day[:year], [pair], 0.0)
        current_day = day
      end
    end
    days
  end

  #------------------------------------------------------------------------
  # Parse an emacs time log file and return a list of TimePair objects
  #------------------------------------------------------------------------
  def self.parse_file file, begin_date, end_date
    line_no = 0
    pairs = []

    while true
      # Obtain a pair of TimeEntry objects and the current line_no
      result = parse_in_out(file, line_no)
      i, o, line_no = result # in, out, line

      # If i is nil, we've hit EOF - exit loop
      break unless i

      unless o
        # o is nil, active interval, use now for second entry
        raise 'expected in entry' unless i.is_start
        # Manually create a Date to avoid having a time zone issue
        o = TimeEntry.new(false, DateTime.parse(Time.now.strftime("%F %T")), nil)
      end

      # We have a complete in/out pair
      if (pair = parse_complete_pair(i, o, begin_date, end_date))
        pairs.concat(pair)
      end

    end

    pairs
  rescue Exception => e
    puts "Parse error on line %d: %s" % [line_no, e.message]
    exit 0
  end

  #------------------------------------------------------------------------
  # Parse a pair of lines (in/out) from an emacs time log file and return
  # a triplet consisting of two TimeEntry objects and the number of lines
  # read. TimeEntry slots will be nil if unable to read or parse a line.
  #------------------------------------------------------------------------
  def self.parse_in_out file, line_no
    # Parse in
    line, lines_read = get_line(file)
    line_no += lines_read
    unless line
      return [nil, nil, line_no]
    end
    start_entry = parse_line(line)

    # Parse out
    line, lines_read = get_line(file)
    line_no += lines_read
    unless line
      return [start_entry, nil, line_no]
    end
    end_entry = parse_line(line)

    return [start_entry, end_entry, line_no]
  rescue Exception => e
    puts "Parse error on line %d: %s" % [line_no, e.message]
    exit 0
  end

  #------------------------------------------------------------------------
  # Parse a line from an emacs time log file and return a TimeEntry
  #------------------------------------------------------------------------
  def self.parse_line line
    raise 'invalid line' unless
      line =~ /^([io]) (\d{4}\/\d\d\/\d\d \d\d:\d\d:\d\d)(?: (\S.*)?)?$/
    TimeEntry.new($1 == 'i',  DateTime.parse($2, true), $3 || '')
  end

  def self.parse_time_entries timelog_path, begin_date, end_date, description, invert_match
    # Parse the file
    begin
      timelog_path = timelog_path
      raise "Unable to find your timelog file at: '#{timelog_path}'" unless
        timelog_path && File.exists?(timelog_path)
      file = File.new(timelog_path, 'r')

      entries = parse_file(file, begin_date, end_date).select do |e|
        match = e[0][:description] =~ /#{description || '.*'}/i
        invert_match ? !match : match
      end

      entries
    ensure
      file.close if file
    end
  end

  #------------------------------------------------------------------------
  # Print a report and accumulate grouping statistics
  #------------------------------------------------------------------------
  def self.print_report days, statistics, group_levels
    # Report
    days.each do |day|
      puts "%s/%s/%s" % [day[:mon], day[:day], day[:year]]
      group_hours = { '' => 0.0 } if statistics
      day.pairs.each do |pair|
        hours = hours_interval(pair)
        puts "%05.2f-%05.2f %s" % (hours + [pair.start.description])
        if statistics
          group_key = compute_group_key(pair.start.description, group_levels)
          group_hours[group_key] = (group_hours[group_key] || 0.0) + (hours[1] - hours[0])
        end
      end
      if statistics
        puts '------------------'
        if group_hours.length > 1
          group_hours.delete('')
          daily_sum = 0.0
          group_hours.sort.each do |key, value|
            puts "%5.2f %s" % [value, key]
            daily_sum += value
          end
        else
          daily_sum = group_hours['']
        end
        puts "%5.2f Daily Total" % daily_sum
        day.group_hours = group_hours
      end
      puts
    end
  end

  def self.print_statistics config, days, today, date_range
    day_starts = config['day_starts']
    work_hours = config['work_hours'] || 7
    end_time = config['end_time'] || '17:00'

    puts 'Daily Hours'
    puts '-----------'
    group_hours = { '' => 0.0 }
    total_sum = 0.0
    days.each do |day|
      daily_sum = 0.0
      day.group_hours.each do |key, value|
        group_hours[key] = (group_hours[key] || 0.0) + value
        daily_sum += value
      end
      puts "%2d/%02.2d/%d: %5.2f" % [day[:mon], day[:day], day[:year], daily_sum]
      total_sum += daily_sum
    end
    puts "Total      %6.2f" % total_sum

    if group_hours.length > 1
      group_hours.delete('')
      puts
      puts 'Most Time Spent'
      puts "---------------"
      billable_sum = 0.0
      non_billable_sum = 0.0
      group_hours.sort {|a,b| b[1] <=> a[1] }.each do |key, value|
        non_billable = (config['non_billable_entities'] || []).any? {|e|
          key.downcase.start_with?(e.downcase)
        }
        puts "%5.2f (%5.1f %%) %s" % [value, (value / total_sum * 100.0), "#{key} #{non_billable ? '*' : ''}"]

        if non_billable
          non_billable_sum += value
        else
          billable_sum += value
        end
      end
    end
    sum = billable_sum + non_billable_sum
    raise 'calculation error' if (sum - total_sum).abs > 0.0001
    puts
    puts "%5.2f Billable hours" % billable_sum
    puts "%5.2f Non-billable hours *" % non_billable_sum
    puts
    puts "%5.2f Total hours - #{date_range}" % sum
    puts

    if today
      puts
      puts 'Daily Stats'
      puts '----------------'

      auto_time = days.first.pairs.first.start.time.to_time
      auto_time -= auto_time.utc_offset

      t1 = day_starts == 'auto' ?
             auto_time :
             DateTime.parse("#{day_starts} #{Time.now.zone}").to_time
      t2 = Time.now

      elapsed_hours = (t2-t1).to_f / 3600.0
      daily_percent = ((total_sum / elapsed_hours) * 100.0)
      eod = Time.now + ((work_hours - total_sum) * 60 * 60)

      puts "%2.2f @ %3.1f%% EOD #{eod.strftime('%H:%M')} vs. #{end_time}" % [total_sum, daily_percent]
      puts ''
    end
  end

  #------------------------------------------------------------------------
  # Split a TimePair object into two TimePair objects before/after midnight
  #------------------------------------------------------------------------
  def self.split_time_pair pair
    first = pair.start.time
    end_of_first = DateTime.civil(first.year, first.mon, first.day, 23, 59, 59)
    second = pair.end.time
    beg_of_second = DateTime.civil(second.year, second.mon, second.day, 0, 0, 0)
    [
     TimePair.new(pair.start, TimeEntry.new(false, end_of_first, nil)),
     TimePair.new(TimeEntry.new(true, beg_of_second, pair.start.description), pair.end)
    ]
  end

  #------------------------------------------------------------------------
  # Builds a date range string from a begin and end TimeDay
  #
  # begin_date: The beginning TimeDay
  # end_date:   The ending TimeDay
  #
  # Returns a string representing the TimeDay date range
  #------------------------------------------------------------------------
  def self.date_range_display(begin_date, end_date)
    return date_string(begin_date) if begin_date == end_date

    date_string(begin_date) + ' to ' + date_string(end_date)
  end

  def self.date_string(date)
    "%02d/%02d/%04d" % [date.mon, date.day, date.year]
  end
end

#------------------------------------------------------------------------
# Run
#------------------------------------------------------------------------

if __FILE__ == $0
  TimeClock.run(ARGV, JSON.parse(IO.read(File.join(File.dirname(__FILE__), 'timeclock.json'))))
end
