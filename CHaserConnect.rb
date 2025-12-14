# frozen_string_literal: true
# encoding: utf-8

require 'socket'

class CHaserConnect
  attr_reader :port_number, :host

  def initialize(name)
    @host = prompt_input("接続先IPアドレスを入力してください")
    port_str = prompt_input("接続先ポート番号を入力してください")
    @port_number = parse_port(port_str)
    @name = encode_name(name, port_str)
    @socket = connect_to_server(@host, port_str)
    send_name
  end

  def port
    @port_number
  end

  def getReady
    log_action("getReady")
    begin
      @socket.gets
      @socket.puts("gr\r")
      parse_response(@socket.gets)
    rescue StandardError
      log_error("getReady")
      nil
    end
  end

  def walkRight
    execute_command("wr", "walkRight")
  end

  def walkLeft
    execute_command("wl", "walkLeft")
  end

  def walkUp
    execute_command("wu", "walkUp")
  end

  def walkDown
    execute_command("wd", "walkDown")
  end

  def lookRight
    execute_command("lr", "lookRight")
  end

  def lookLeft
    execute_command("ll", "lookLeft")
  end

  def lookUp
    execute_command("lu", "lookUp")
  end

  def lookDown
    execute_command("ld", "lookDown")
  end

  def searchRight
    execute_command("sr", "searchRight")
  end

  def searchLeft
    execute_command("sl", "searchLeft")
  end

  def searchUp
    execute_command("su", "searchUp")
  end

  def searchDown
    execute_command("sd", "searchDown")
  end

  def putRight
    execute_command("pr", "putRight")
  end

  def putLeft
    execute_command("pl", "putLeft")
  end

  def putUp
    execute_command("pu", "putUp")
  end

  def putDown
    execute_command("pd", "putDown")
  end

  def close
    @socket.close
  end

  private

  def prompt_input(message)
    puts(message)
    gets.chomp
  end

  def parse_port(port_str)
    port_str.to_i if port_str&.match?(/\A\d+\z/)
  end

  def encode_name(name, port_str)
    if port_str == "40000" || port_str == "50000"
      name.encode('CP932')
    else
      name
    end
  end

  def connect_to_server(host, port)
    retry_count = 0
    loop do
      begin
        return TCPSocket.open(host, port)
      rescue StandardError
        retry_count += 1
        handle_connection_retry(retry_count)
        sleep(1)
      end
    end
  end

  def handle_connection_retry(retry_count)
    if retry_count == 1
      puts "\"#{display_name}\"はサーバに接続出来ませんでした"
      puts "サーバが起動しているかどうか or ポート番号、IPアドレスを確認してください"
      puts "接続できるまで待機します..."
    elsif (retry_count % 30).zero?
      puts "まだ接続できません... (#{retry_count}秒経過) - 接続を試行中"
    end
  end

  def send_name
    @socket.puts(@name)
    puts "\"#{display_name}\"はサーバに接続しました"
  end

  def display_name
    @name.encode("UTF-8")
  end

  def execute_command(command, action_name)
    log_action(action_name)
    @socket.puts("#{command}\r\n")
    result = parse_response(@socket.gets)
    @socket.puts("\#\r\n")
    result
  end

  def log_action(action)
    puts "\"#{display_name}\"は#{action}をサーバに送信"
  end

  def log_error(action)
    puts "\"#{display_name}\"は#{action}をサーバに送信できませんでした"
  end

  def parse_response(response)
    result = Array.new(10, 9)
    10.times do |i|
      result[i] = response[i].to_i
      print result[i]
    end
    print "\n"
    result
  end
end

if __FILE__ == $0
  client = CHaserConnect.new("test")

  loop do
    ready_result = client.getReady
    break if ready_result[0].zero?

    search_result = client.searchUp
    break if search_result[0].zero?
  end

  client.close
end
