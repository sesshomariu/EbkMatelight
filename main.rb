#!/usr/bin/ruby

require 'socket'
load 'font.rb'
$RASPBIAN = !(/arm-linux-gnueabihf/=~RUBY_PLATFORM).nil?
$RASPBIAN = ARGV.shift!="--simulate"

$PXCOL = "00ffff"
def puts(s); $stdout << "[#{Time.now.to_s}] #{s}\n" ;end  # define output with timestamp
class Integer;def to_led_bin;self!=0 ? (return $PXCOL.to_i(16)) : (return 0);end;end
$RASPBIAN ? (puts "require 'ws2812'";require('ws2812')) : (puts "SIMULATION MODE")

class EbkMateCanvas

  def initialize
    @canvas = []
    @addresses = []
    @@addrc = 0
    @leds = nil
    @mode = :binary
    @bx = 5
    @by = 8
    @by.times{ @canvas << Array.new; @bx.times{@canvas[-1] << 0} }
    @by.times{ @addresses << Array.new; @bx.times{@addresses[-1] << @@addrc; @@addrc+=1} }
    #@addresses.map!{|i|@addresses.index(i)%2==0;i.reverse;i}
    @addresses.length.times{|i|i%2==0&&@addresses[i].reverse!}
    $RASPBIAN&&(@leds=Ws2812::Basic.new(40, 18, 255); @leds.open;@leds.show)
  end

  attr_accessor :canvas
  attr_accessor :mode
  attr_reader :bx
  attr_reader :by

  def show
    # TODO Make the EbkMateCanvas.show() method
    canv_local = @canvas

    if $RASPBIAN
      canv_local.each_with_index do |y, indexy|
        y.each_with_index do |x, indexx|
          hexcol = "%06x"%canv_local[indexy][indexx]
          (hexcol = "%06x"%hexcol.to_i(16).to_led_bin) if mode==:binary
          @leds[@addresses.flatten[indexy*5+indexx]] = Ws2812::Color.new(hexcol[0,2].to_i(16),hexcol[2,2].to_i(16),hexcol[4,2].to_i(16))
        end
      end
      @leds.show
      #gets
    else
      for byte in canv_local
        $stdout << byte.inspect << "\n"
      end
      $stdout << "\n"
    end

  end

  def shift
    @canvas.length.times { |t| @canvas[t].shift }
  end

  def <<(a)
    @canvas.length.times { |t| @canvas[t].shift }
    a.each_with_index { |item, index| @canvas[index] << item }
  end

  def clear
    @canvas = []
    @by.times{ @canvas << Array.new; @bx.times{@canvas[-1] << 0} }
  end

end

$QUEUE = []
$CANVAS = EbkMateCanvas.new
$BLACKLIST = {}
$COOLDOWN = []
$COOLDOWN_S = 1
$THREADS = []
$MAINTENANCE = false
$CLIENTS = []

$GAPS = 3


server = TCPServer.new(1337)
puts "Server is up."

def showPic(data)
  begin
    $CANVAS.mode = :rgb
    data = data.split(";")
    decay = data.shift.split("=")[-1]
    (decay.split("=")[-1].to_i>10000||decay.split("=")[-1].to_i<0)&&raise
    data.length==40||raise
    $CANVAS.by.times{|cy|
	$CANVAS.bx.times{|cx|
		$CANVAS.canvas[cy][cx] = data.shift.to_i(16)
	}
    }
    $CANVAS.show
    sleep decay.split("=")[-1].to_i/1000
    $CANVAS.clear
    $CANVAS.show
    return 0
  rescue
    $CANVAS.clear
    $CANVAS.show
    return 1
  end
end

queuewatch = Thread.new {
  require 'timeout'
  loop do
    if !$QUEUE.empty?
      msg = $QUEUE.shift
      if !(msg[0,2]=="d=")
	$CANVAS.clear
      	$CANVAS.mode = :binary
      	for ch in msg.split("")
      	  case ch
      	    when " "
     	       6.times { $CANVAS << Array.new(8){0}; $CANVAS.show; sleep 0.05 }
	
            when "\""
              5.times do |i|
                buf = []
                getFontChar(ch).each { |byte| buf << byte[i+1] }
                buf.map!(&:to_i)
                $CANVAS << buf;$CANVAS.show;sleep 0.04
              end
              $GAPS.times { $CANVAS << Array.new(8){0}; $CANVAS.show; sleep 0.05 }
  
            else
              8.times do |i|
                buf = []
                getFontChar(ch).each { |byte| buf << byte[i] }
                buf.map!(&:to_i)
                buf.all?(&0.method(:==))||($CANVAS << buf;$CANVAS.show;sleep 0.04)
              end
              $GAPS.times { $CANVAS << Array.new(8){0}; $CANVAS.show; sleep 0.05 }
          end
        end
        $CANVAS.canvas[0].length.times { $CANVAS << Array.new(8){0}; $CANVAS.show; sleep 0.05 }
      	sleep 1
      else
        showPic(msg)
      end
    end
  end
}

Thread.new {
  loop do
    (/false|dead/=~queuewatch.status.to_s).nil?||Process.kill("KILL",$$)
    sleep 1
  end
}

def adminMenu(client)
  client.puts "Welcome, #{client.peeraddr[-1]}. What do you want to do?"
  loop do
    client.puts "1) Blacklist IP"
    client.puts "2) Pardon IP"
    client.puts "3) Send a text"
    client.puts "4) Toggle maintenance (currently #{$MAINTENANCE ? "on" : "off"})"
    client.puts "5) Kill server"
    client.puts "6) Set pixel color of text"
    client.puts "0) Exit"
    case client.gets.chomp

      when "0"
        return

      when "1"
        client.puts "Enter IP to blacklist(q to quit)"
        client_in_ip = client.gets.chomp
        if !client_in_ip=="q"&&!client_in_ip=="127.0.0.1"
          client.puts "Why do you want to blacklist #{client_in_ip}?(q to quit)"
          client_in_rs = client.gets.chomp
          unless client_in_rs=="q"
            $BLACKLIST.store(client_in_ip, client_in_rs)
            client.puts "#{client_in_ip} was blacklisted. Reason: #{client_in_rs}"
          end
          elsif client_in_ip=="127.0.0.1"
            client.puts "You can't blacklist yourself!"
        end

      when "2"
        client.puts "Which IP do you want to pardon?(q to quit) $BLACKLIST currently looks like this: "
        client.puts $BLACKLIST.inspect
        client_in_ip = client.gets.chomp
        unless client_in_ip=="q"
          $BLACKLIST.delete(client_in_ip).nil?&&("E: #{client_in_ip} wasn't blacklisted.")
        end

      when "3"
        client.puts "O HAI ENTR STRING PLZ!!1!1!!!11"
        climsg = client.gets.chomp
        client.puts "KTHXBYE!!1!1!!"
        puts "#{client.peeraddr[-1]} => #{climsg.inspect}"
        $QUEUE << climsg

      when "4"
        if $MAINTENANCE
          $MAINTENANCE = false
        else
          until $CLIENTS.empty?;$CLIENTS.shift.close;end
          until $THREADS.empty?;$THREADS.shift.kill; end
          $MAINTENANCE = true
        end
        client.puts "Maintenance toggled. => #{$MAINTENANCE ? "on" : "off"}"

      when "5"
        client.puts "Shutting down."
        puts "RECEIVED SIGINT"
        $MAINTENANCE = true
        until $CLIENTS.empty?;$CLIENTS.shift.close;end
        until $THREADS.empty?;$THREADS.shift.kill; end
        Thread.new {sleep 2; Process.kill("INT",$$)}
        return

      when "6"
        begin
          client.puts "Enter color(example: c00deed)"
          pxcol_temp = client.gets.chomp
          (pxcol_temp.length!=6||pxcol_temp.match(/[^[0-9a-f]]/)!=nil)&&raise
          $PXCOL = pxcol_temp
          puts "$PXCOL => #{$PXCOL.inspect}"
        rescue

        end
      else
        client.puts "Invalid command"
    end
  end
end

Thread.new {
  $THREADS.select!{|i|i.status!=false}
  sleep 1
}

$ADMINS = ["127.0.0.1"]#,"192.168.21.187","192.168.21.155"]
$ADMINS = Regexp.new($ADMINS.join("|"))

Signal.trap("INT") {
  puts "Bye"
  $CANVAS.clear
  $CANVAS.show
  exit
}

loop do
  $THREADS << Thread.start(server.accept) do |client|
    if ($ADMINS=~client.peeraddr[-1]).nil?&&!$MAINTENANCE
      $CLIENTS << client
        if !$BLACKLIST.keys.include?(client.peeraddr[-1])&&!$COOLDOWN.include?(client.peeraddr[-1])
          #client.puts "Mode?"
          #client.puts "0) Text"
          #client.puts "1) Picture"
          #mode = client.gets.chomp
          #if mode=="0"
            client.puts "O HAI GIMMEH DATA PLZ!!1!1!!!11"
            climsg = client.gets.chomp
            #Thread.new{$COOLDOWN<<client.peeraddr[-1]; sleep $COOLDOWN_S; $COOLDOWN.select!(&client.peeraddr[-1].method(:==))}
            if climsg.length>60&&climsg[0,2]!="d="
              climsg = climsg[0,60]
              client.puts "Your message overrode the maximum length of 60 characters and was chopped down to:"
              client.puts climsg.inspect
            end
            client.puts "KTHXBYE!!1!1!!"
            puts "#{client.peeraddr[-1]} => #{climsg.inspect}(#{climsg[0,2]=="d=" ? "PICTURE" : "TEXT"})"
            $QUEUE << climsg
          #elsif mode=="1"
            #client.puts "Enter formatted string:"
            #data = client.gets.chomp
            #$QUEUE << data
            #res = showPic(data)
            #res==1&&Random.rand(100)==42 ? client.puts("it's me") : client.puts("err")
          #end
        client.close
      elsif $COOLDOWN.include?(client.peeraddr[-1])
        $COOLDOWN.select!(&client.peeraddr[-1].method(:==))
        $BLACKLIST[client.peeraddr[-1]] = "Cooldown wasn't expired"
        client.puts "You have been blacklisted by the owner."
        client.puts "Reason: #{$BLACKLIST[client.peeraddr[-1]]}"
        client.close
      else
        client.puts "You have been blacklisted by the owner."
        client.puts "Reason: #{$BLACKLIST[client.peeraddr[-1]]}"
        client.close
      end
    elsif !($ADMINS=~client.peeraddr[-1]).nil?
      $THREADS.pop
      adminMenu(client)
      client.close
    else
      client.puts "MAINTENANCE IN PROGRESS"
      client.close
    end
  end
end
