#!/usr/bin/ruby

require 'rubygems'

require 'pp'
require 'pry'
require 'id3lib'
require 'nokogiri'
require 'open-uri'
require 'watir-webdriver'

# wtf ruby
class String
  def title(); self.split(/(\W)/).map(&:capitalize).join; end
end

def do_ascpt(scpt); `osascript -e '#{scpt}'`; end

def start_esd()
  pcs = IO.popen('esd -tcp -bind ::1')
  sleep 1
  pcs.pid
end

def stop_pcs(pid)
  sleep 5
  `kill #{pid}`
  sleep 1
end

def stop_rec()
  plist = `ps aux | grep esdrec | grep -v grep | awk '{print $2}'`.split("\n")
  plist.each{ |p| Process.kill 1, p.to_i }
end

def start_rec(track)
  fn = track_filename(track)
  # 2>&1 >/dev/null
  c = "esdrec -s ::1 | ffmpeg -f s16le -ac 2 -i - -acodec libmp3lame -ab 256k \"#{fn}\""
  p c
  pcs = IO.popen(c)
  sleep 2
  pcs.pid
end

def set_input_output()

scpt = <<END
  tell application "System Preferences"
     activate
     set current pane to pane "com.apple.preference.sound"
     reveal (first anchor of current pane whose name is "output")
  end tell

  tell application "System Events"
     launch
     tell process "System Preferences"
         set theRows to every row of table 1 of scroll area 1 of tab group 1 of window 1
         repeat with aRow in theRows
             if (value of text field 1 of aRow) is equal to "Soundflower (2ch)" then
                 set selected of aRow to true
                 exit repeat
             end if
         end repeat
     end tell
  end tell

  tell application "System Preferences"
     activate
     set current pane to pane "com.apple.preference.sound"
     reveal (first anchor of current pane whose name is "input")
  end tell

  tell application "System Events"
     launch
     tell process "System Preferences"
         set theRows to every row of table 1 of scroll area 1 of tab group 1 of window 1
         repeat with aRow in theRows
             if (value of text field 1 of aRow) is equal to "Soundflower (2ch)" then
                 set selected of aRow to true
                 exit repeat
             end if
         end repeat
     end tell
  end tell
END

  do_ascpt(scpt)

end

def unset_input_output()

scpt = <<END
  tell application "System Preferences"
     activate
     set current pane to pane "com.apple.preference.sound"
     reveal (first anchor of current pane whose name is "output")
  end tell

  tell application "System Events"
     launch
     tell process "System Preferences"
         set theRows to every row of table 1 of scroll area 1 of tab group 1 of window 1
         repeat with aRow in theRows
             if (value of text field 1 of aRow) is equal to "Display Audio" then
                 set selected of aRow to true
                 exit repeat
             end if
         end repeat
     end tell
  end tell

  tell application "System Preferences"
     activate
     set current pane to pane "com.apple.preference.sound"
     reveal (first anchor of current pane whose name is "input")
  end tell

  tell application "System Events"
     launch
     tell process "System Preferences"
         set theRows to every row of table 1 of scroll area 1 of tab group 1 of window 1
         repeat with aRow in theRows
             if (value of text field 1 of aRow) is equal to "Display Audio" then
                 set selected of aRow to true
                 exit repeat
             end if
         end repeat
     end tell
  end tell
END

  do_ascpt(scpt)

end

def song_page(myspace_name)
  "http://www.myspace.com/#{myspace_name}/music/songs"
end

def max_volume(); do_ascpt('set volume 7'); end

def get_track_info(url)

  tracks = []

  doc = Nokogiri::HTML(open(url))
  prefix = 'div.group > div.songDetails >'
  artist_name = doc.css('div.artistName a').first.text.title
  doc.css('ol.songList > li.song').each do |n|

    track_title = n.css("#{prefix} strong > a > span").first.text.title.gsub('"','')
    track_length = n.css("#{prefix} div.number > span.duration").first.text
    dt = DateTime.strptime(track_length, '%M:%S')
    track_length_seconds = dt.hour * 3600 + dt.min * 60 + dt.sec

    button_path = n.css('.playCirclePlayerIcon27').first.css_path

    printf "%s, %s, %s \n", artist_name.title(), track_title, track_length_seconds

    tracks << { :title => track_title, 
                :length => track_length_seconds,
                :artist => artist_name, 
                :button_path => button_path }

  end

  tracks

end

def track_filename(track)
  artist = track[:artist].gsub(",",'')
  title = track[:title].gsub('/','-').gsub('\\','-').gsub("'",'')
  "#{artist}/#{title}.mp3"
end

def record_tracks(url, tracks)

  tracks.each do |track|

    next if File.exists? track_filename(track)

    sleep_time = 2 + track[:length]

    begin

      browser = Watir::Browser.new :chrome
      browser.goto url
      p track
      rec_pid = start_rec(track)
      # ensure the element is visible
      el = browser.element(:css => track[:button_path])
      # remove the header so it doesnt get in the way of our click
      browser.execute_script("h = document.querySelectorAll('header\#globalHeader')[0]; h.parentNode.removeChild(h);")
      browser.execute_script('arguments[0].scrollIntoView(true);', el)
      el.click
      sleep sleep_time

    rescue => e

      puts e.message
      puts e.backtrace

    ensure
      stop_rec()
      browser.close
    end

    set_id3(track)

  end

end

def set_id3(track)
  fn = track_filename(track)
  tag = ID3Lib::Tag.new(fn)
  tag.title = track[:title]
  tag.artist = track[:artist]
  tag.update!
  p tag
end

def prepare_dir(artist_name)
  dirname = artist_name.gsub(",",'')
  `rm -rf "#{artist_name}"`
  `mkdir "#{dirname}"`
end

def trim_tracks(tracks)

  tracks.each do |track|

    fn = track_filename(track)
    trim_fn = fn.gsub('mp3', 'wav').gsub('.', '_trim.')
    silence_fn = trim_fn.gsub('_trim', '_silence')
    pad_fn = silence_fn.gsub('_silence', '_pad')
    
    puts "Trimming #{fn}"

    # trim to remove pop at start
    `sox -b 90 -e ms-adpcm "#{fn}" "#{trim_fn}" trim 0.1`

    # remove early silence
    `sox "#{trim_fn}" "#{silence_fn}" silence 1 0 -40d`

    `sox "#{silence_fn}" "#{pad_fn}" pad 1 1`

    # re-encode to mp3
    `ffmpeg -y -i "#{pad_fn}" \
            -acodec libmp3lame -ab 256k "#{fn}"`

    # reset id3 tag
    set_id3(track)

    # clean up 
    `rm "#{trim_fn}"`
    `rm "#{silence_fn}"`
    `rm "#{pad_fn}"`

    # check and correct any mp3 file format errors
    `mp3check --cut-junk-start \
              --cut-junk-end \
              --cut-tag-end \
              --fix-headers \
              --fix-crc "#{fn}"`

  end

end

myspace_name = ARGV.shift 

max_volume()
set_input_output()
esd_pid = start_esd()

artist_url = song_page(myspace_name)
tracks = get_track_info(artist_url)
artist_name = tracks.first[:artist]

tracks = tracks

prepare_dir(artist_name)
record_tracks(artist_url, tracks)
stop_pcs(esd_pid)
unset_input_output()

trim_tracks(tracks)
