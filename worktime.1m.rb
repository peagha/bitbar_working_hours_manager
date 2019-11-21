#!/usr/bin/env /Users/peagha/.rbenv/shims/ruby

# <bitbar.title>Working Hours Manager</bitbar.title>
# <bitbar.version>v0.1</bitbar.version>
# <bitbar.author>Philippe Hardardt</bitbar.author>
# <bitbar.author.github>peagha</bitbar.author.github>
# <bitbar.desc></bitbar.desc>
# <bitbar.image></bitbar.image>
# <bitbar.abouturl>https://github.com/peagha/bitbar_working_hours_manager</bitbar.abouturl>

# TODO:
# - make script compatible with older versions of Ruby
# - add GF create time entry
# - highlight unapproved ifponto entries
# - highlight GF / IFPonto differences
# - add GF details
# - test cache entry

require 'net/http'
require 'uri'
require 'json'
require 'cgi'
require 'date'
require 'pstore'
require 'open3'
require 'set'

module TimeExtensions
  refine Integer do
    def minutes
      self * 60
    end

    def hours
      minutes * 60
    end

    def days
      hours * 24
    end

    alias day    days
    alias hour   hours
    alias minute minutes
  end
end

def TimeStamp(hours_or_value, minutes = :nd)
  if minutes == :nd
    case hours_or_value
    when Time then TimeStamp.new(hours_or_value.hour, hours_or_value.min)
    when Float then TimeStamp.new(0, hours_or_value * 60)
    when String then
      hours, minutes = hours_or_value.split(':')
      TimeStamp.new(Integer(hours, 10), Integer(minutes, 10))
    else raise ArgumentError
    end
  else
    TimeStamp.new(hours_or_value, minutes)
  end
end

class TimeStamp
  attr_reader :hours, :minutes

  def initialize(hours, minutes)
    @hours = hours
    @minutes = minutes

    while @minutes < 0
      @hours -= 1
      @minutes += 60
    end

    while @minutes >= 60
      @hours += 1
      @minutes -= 60
    end
  end

  def to_s
    sprintf('%.2d:%.2d', @hours, @minutes)
  end

  def ==(other)
    self.minutes == other.minutes && self.hours == other.hours
  end

  def -(other)
    TimeStamp.new(self.hours - other.hours, self.minutes - other.minutes)
  end

  def +(other)
    TimeStamp.new(self.hours + other.hours, self.minutes + other.minutes)
  end

  def to_minutes
    self.hours * 60 + self.minutes
  end

  def inspect
    "#<TimeStamp #{to_s}>"
  end
end

class Today
  def initialize(started, break_time = TimeStamp(1, 15))
    @started = started
    @break_time = break_time
  end

  def started
    @started
  end

  def ends
    @started + @break_time + TimeStamp(8, 0)
  end

  def worked(now = TimeStamp(Time.now))
    now - @started - lunch_time_elapsed_minutes(now)
  end

  private

  def lunch_time_elapsed_minutes(now)
    elapsed = now - TimeStamp(12, 0)

    TimeStamp(0, elapsed.to_minutes.clamp(0, @break_time.to_minutes))
  end
end

class IFPontoClient
  def initialize
    @credentials = CachedIfPontoCredentials.new
  end

  def start_time(date)
    @credentials.with_token do |token|
      response = Net::HTTP.post(
        URI('https://ifractal.srv.br/ifPonto/plataformatec/db/select_ponto.php?pag=ponto_espelho'),
        "cmd=get_espelho2&de=#{date.strftime('%d/%m/%Y')}&ate=#{date.strftime('%d/%m/%Y')}&posicao=0&cod_funcionario=&funcionario=&cod_cargo=&cargo=&cod_depto=&depto=&cod_empresa=&empresa=&tipo_salario=&tipo_pessoa=&demitido=false&bloqueado=false",
        'Cookie' => "iFractal_Sistemas=#{token}"
      )
      throw(:invalid_token) unless response.code == '200'

      entry = JSON.parse(response.body)['itens'].first['mc1']
      if ['FALTA', 'FOLGA', nil, '* A'].include?(entry)
        nil
      else
        TimeStamp(entry)
      end
    end
  end

  def worked(date)
    @credentials.with_token do |token|
      response = Net::HTTP.post(
        URI('https://ifractal.srv.br/ifPonto/plataformatec/db/select_ponto.php?pag=ponto_espelho'),
        "cmd=get_espelho2&de=#{date.strftime('%d/%m/%Y')}&ate=#{date.strftime('%d/%m/%Y')}&posicao=0&cod_funcionario=&funcionario=&cod_cargo=&cargo=&cod_depto=&depto=&cod_empresa=&empresa=&tipo_salario=&tipo_pessoa=&demitido=false&bloqueado=false",
        'Cookie' => "iFractal_Sistemas=#{token}"
      )
      entry = JSON.parse(response.body)['itens'].first
      worked_float = entry['t_h_total_calculado'].to_f

      if worked_float > 0 && entry['mc1'] != '* A'
        # handle lunch time not loaded; mc3 is nil when lunch time isn't loaded yet
        if entry['mc3'].nil?
          TimeStamp(worked_float) - TimeStamp(entry['total_intervalo'])
        else
          TimeStamp(worked_float)
        end
      else
        entry['alteracao'].split.each_slice(2).sum(TimeStamp('00:00')) do |start_time, end_time|
          TimeStamp(end_time) - TimeStamp(start_time)
        end
      end
    end
  end
end

class CachedIFPontoClient
  using TimeExtensions

  def initialize(client = IFPontoClient.new, cache_store = PStoreCacheStore.new)
    @client = client
    @cache_store = cache_store
  end

  def start_time(date)
    expire_after_rule = ->(value) { value.nil? ? (10.minutes) : nil }
    @cache_store.fetch("start_time:#{date.strftime('%Y-%m-%d')}", expire_after_rule: expire_after_rule) do
      @client.start_time(date)
    end
  end

  def worked(date)
    expire_after_rule = ->(value) { value == TimeStamp('0:00') ? 1.hour : 1.day }
    @cache_store.fetch("worked:#{date.strftime('%Y-%m-%d')}", expire_after_rule: expire_after_rule) do
      @client.worked(date)
    end
  end
end

class IfPontoCredentials
  def initialize
    @credential_source = CredentialDialog.new
  end

  def with_token
    yield(request_token)
  end

  def request_token
    response = Net::HTTP.post(
      URI('https://ifractal.srv.br/ifPonto/plataformatec/header.php'),
      "login=#{user}&senha=#{password}",
    )
    cookie = CGI::Cookie.parse(response.header['Set-Cookie'])
    cookie['iFractal_Sistemas'].first
  end

  private

  def user
    @credential_source.ifponto_username
  end

  def password
    @credential_source.ifponto_password
  end
end

class CachedIfPontoCredentials
  def initialize(ifponto_credentials = IfPontoCredentials.new, cache_store = PStoreCacheStore.new)
    @ifponto_credentials = ifponto_credentials
    @cache_store = cache_store
  end

  def with_token
    result = catch(:invalid_token) { yield(request_token) }

    if result
      result
    else
      new_token = @ifponto_credentials.request_token
      @cache_store.write('ifponto_token', new_token)
      yield(new_token)
    end
  end

  def request_token
    @cache_store.fetch('ifponto_token') { @ifponto_credentials.request_token }
  end
end

class PStoreCacheStore
  def initialize
    @pstore = PStore.new('/tmp/settings.pstore')
  end

  def fetch(key, expire_after: nil, expire_after_rule: ->(_) { expire_after })
    cached_value = read(key)

    if cached_value && !cached_value.expired?
      cached_value.value
    else
      yield.tap do |new_value|
        write(key, new_value, expire_after_rule.call(new_value))
      end
    end
  end

  def read(key)
    @pstore.transaction { |store| store[key] }
  end

  def write(key, value, expire_after = nil)
    @pstore.transaction { |store| store[key] = Entry.new(value, expire_after) }
  end

  class Entry
    attr_reader :value

    def initialize(value, expire_after = nil, created = Time.now)
      @value = value
      @expire_after = expire_after
      @created = created
    end

    def expired?(now = Time.now)
      @expire_after && @created + @expire_after < now
    end
  end

  def clear
    keep = %w[
      ifponto_username
      ifponto_password
      ifponto_token
      glass_factory_member_id
      glass_factory_token
      glass_factory_email
    ]
    @pstore.transaction do
      (@pstore.roots - keep).each { |key| @pstore.delete(key) }
    end
  end

  def clear_all
    @pstore.transaction do
      @pstore.roots.each { |key| @pstore.delete(key) }
    end
  end

  def entries
    @pstore.transaction do
      @pstore.roots.map { |key| [key, @pstore[key]] }.to_h
    end
  end
end

class CredentialDialog
  def initialize(store = PStoreCacheStore.new)
    @store = store
  end

  def ifponto_username
    @store.fetch('ifponto_username') { dialog('Usuário do IFPonto:') }
  end

  def ifponto_password
    @store.fetch('ifponto_password') { dialog('Senha do IFPonto:') }
  end

  def glass_factory_member_id
    @store.fetch('glass_factory_member_id') { dialog('User ID do GlassFactory:') }
  end

  def glass_factory_email
    @store.fetch('glass_factory_email') { dialog('Email do GlassFactory:') }
  end

  def glass_factory_token
    @store.fetch('glass_factory_token') { dialog('Token do GlassFactory:') }
  end

  def dialog(message)
    script = 'Tell application "System Events" to display dialog "' + message + '" default answer ""'
    Open3.capture3('osascript', *['-e', script, '-e', 'text returned of result'])
      .first
      .strip
      .force_encoding('UTF-8')
  end
end

class GlassFactoryClient
  def initialize
    @credential_source = CredentialDialog.new
  end

  def worked(date)
    query_string = URI.encode_www_form(
      start: date.strftime('%Y-%m-%d'),
      end: date.strftime('%Y-%m-%d')
    )

    member_id = @credential_source.glass_factory_member_id
    url = URI("https://plataformatec.glassfactory.io/api/public/v1/members/#{member_id}/time_logs.json?#{query_string}")

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(url)
    request['X-User-Token'] = @credential_source.glass_factory_token
    request['X-User-Email'] = @credential_source.glass_factory_email

    minutes = JSON.parse(http.request(request).body).sum { |entry| entry['time'] } / 60
    TimeStamp(0, minutes)
  end

  def projects
    url = URI('https://plataformatec.glassfactory.io/api/public/v1/projects.json')

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Get.new(url)
    request['X-User-Token'] = @credential_source.glass_factory_token
    request['X-User-Email'] = @credential_source.glass_factory_email
    JSON.parse(http.request(request).body, symbolize_names: true)
      .reject { |closed:, **| closed }
      .map { |id:, name:, **| Project.new(id, name) }
  end

  def activities(project_id)
    url = URI("https://plataformatec.glassfactory.io/api/public/v1/projects/#{project_id}/activities.json")
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(url)
    request['X-User-Token'] = @credential_source.glass_factory_token
    request['X-User-Email'] = @credential_source.glass_factory_email
    JSON.parse(http.request(request).body, symbolize_names: true)
      .map { |id:, name:, **| Activity.new(id, name) }
  end

  def track_time(date, worked, description, activity_id)
    query_string = URI.encode_www_form(
      activity_id: activity_id,
      date: date.strftime('%Y-%m-%d'),
      time: worked.to_minutes * 60, # seconds
      comment: description
    )
    member_id = @credential_source.glass_factory_member_id
    url = URI("https://plataformatec.glassfactory.io/api/public/v1/members/#{member_id}/time_logs.json?#{query_string}")

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(url)
    request['X-User-Token'] = @credential_source.glass_factory_token
    request['X-User-Email'] = @credential_source.glass_factory_email

    http.request(request).code == '200'
  end

  Project = Struct.new(:id, :name)
  Activity = Struct.new(:id, :name)
end

class CachedGlassFactoryClient
  using TimeExtensions

  def initialize(client = GlassFactoryClient.new, cache_store = PStoreCacheStore.new)
    @client = client
    @cache_store = cache_store
  end

  def worked(date)
    @cache_store.fetch("gf_worked:#{date.strftime('%Y-%m-%d')}", expire_after: 6.hours) do
      @client.worked(date)
    end
  end
end

if defined?(RSpec)
  class MemoryCache
    def initialize
      @store = {}
    end

    def fetch(key, **)
      cached_value = read(key)
      if cached_value
        cached_value
      else
        yield.tap do |new_value|
          write(key, new_value)
        end
      end
    end

    def read(key)
      @store[key]
    end

    def write(key, value)
      @store[key] = value
    end
  end

  RSpec.describe CachedIFPontoClient do
    describe '#start_time' do
      it 'caches the result' do
        client = double(IFPontoClient)
        allow(client).to receive(:start_time).with(Date.today).and_return(TimeStamp('10:00'))
        allow(client).to receive(:start_time).with(Date.today - 1).and_return(TimeStamp('10:30'))
        cached_client = CachedIFPontoClient.new(client, MemoryCache.new)

        expect(cached_client.start_time(Date.today)).to eq(TimeStamp('10:00'))
        expect(cached_client.start_time(Date.today - 1)).to eq(TimeStamp('10:30'))
        expect(cached_client.start_time(Date.today)).to eq(TimeStamp('10:00'))
        expect(cached_client.start_time(Date.today - 1)).to eq(TimeStamp('10:30'))

        expect(client).to have_received(:start_time).with(Date.today).once
        expect(client).to have_received(:start_time).with(Date.today - 1).once
      end
    end

    describe '#worked' do
      it 'caches the result' do
        client = double(IFPontoClient)
        allow(client).to receive(:worked).with(Date.today).and_return(TimeStamp('08:00'))
        allow(client).to receive(:worked).with(Date.today - 1).and_return(TimeStamp('08:30'))
        cached_client = CachedIFPontoClient.new(client, MemoryCache.new)

        expect(cached_client.worked(Date.today)).to eq(TimeStamp('08:00'))
        expect(cached_client.worked(Date.today - 1)).to eq(TimeStamp('08:30'))
        expect(cached_client.worked(Date.today)).to eq(TimeStamp('08:00'))
        expect(cached_client.worked(Date.today - 1)).to eq(TimeStamp('08:30'))

        expect(client).to have_received(:worked).with(Date.today).once
        expect(client).to have_received(:worked).with(Date.today - 1).once
      end
    end
  end

  RSpec.describe CachedIfPontoCredentials do
    let(:cache_store) { MemoryCache.new }

    describe '#with_token' do
      it 'caches the token' do
        ifponto_credentials = double(IfPontoCredentials, request_token: 'token')
        cached_credentials = CachedIfPontoCredentials.new(ifponto_credentials, cache_store)
        yielded = []

        tokens = Array.new(2) do
          cached_credentials.with_token { |token| yielded << token; token }
        end

        expect(yielded).to eq(['token', 'token'])
        expect(tokens).to eq(['token', 'token'])
        expect(ifponto_credentials).to have_received(:request_token).once
      end

      it 'yields a new token when :invalid_token is thrown' do
        ifponto_credentials = double(IfPontoCredentials)
        allow(ifponto_credentials).to receive(:request_token).and_return('first_token', 'second_token')
        cached_credentials = CachedIfPontoCredentials.new(ifponto_credentials, cache_store)

        token = cached_credentials.with_token do |token|
          throw(:invalid_token) if token == 'first_token'
          token
        end

        expect(token).to eq('second_token')
      end
    end
  end

  RSpec.describe Today do
    describe '#ends' do
      it 'returns the time when the expected work hours are complete' do
        started = TimeStamp('10:00')
        today = Today.new(started)

        expect(today.ends).to eq(TimeStamp('19:15'))
      end
    end

    describe '#started' do
      it 'is equal to the start time' do
        started = TimeStamp('10:00')
        today = Today.new(started)

        expect(today.started).to eq(started)
      end
    end

    describe '#worked' do
      it 'shows how much time is complete so far' do
        started = TimeStamp(10, 0)
        today = Today.new(started)
        now = TimeStamp('11:00')

        expect(today.worked(now)).to eq(TimeStamp('01:00'))
      end

      it 'stops the clock during break time' do
        started = TimeStamp('10:00')
        today = Today.new(started)

        now = TimeStamp('12:00')
        expect(today.worked(now)).to eq(TimeStamp('02:00'))

        now = TimeStamp('12:01')
        expect(today.worked(now)).to eq(TimeStamp('02:00'))

        now = TimeStamp('13:15')
        expect(today.worked(now)).to eq(TimeStamp('02:00'))

        now = TimeStamp('13:16')
        expect(today.worked(now)).to eq(TimeStamp('02:01'))
      end
    end
  end

  RSpec.describe TimeStamp do
    describe 'overflow' do
      it 'handles minutes above 59' do
        expect(TimeStamp(8,60)).to eq(TimeStamp(9,0))
        expect(TimeStamp(8,61)).to eq(TimeStamp(9,1))
      end

      it 'handles minutes below 0' do
        expect(TimeStamp(8,-1)).to eq(TimeStamp(7,59))
        expect(TimeStamp(8,-61)).to eq(TimeStamp(6,59))
      end
    end

    describe '#to_minutes' do
      it 'converts hours into minutes' do
        expect(TimeStamp(1, 1).to_minutes).to eq(61)
      end
    end

    describe '#to_s' do
      it 'generates a string that represents the time stamp' do
        expect(TimeStamp(8,30).to_s).to eq('08:30')
        expect(TimeStamp(11,30).to_s).to eq('11:30')
      end
    end

    describe '#==' do
      it 'compares two time stamps' do
        expect(TimeStamp('08:30')).to eq(TimeStamp('08:30'))
        expect(TimeStamp('08:30')).not_to eq(TimeStamp('08:31'))
      end
    end

    describe '#-' do
      it 'subtracts one time stamp from another' do
        expect(TimeStamp('08:00') - TimeStamp('00:10')).to eq(TimeStamp('7:50'))
      end
    end

    describe '#+' do
      it 'adds two time stamps' do
        expect(TimeStamp('08:30') + TimeStamp('1:30')).to eq(TimeStamp('10:00'))
      end
    end

    describe 'TimeStamp()' do
      it 'parses float values' do
        expect(TimeStamp(7.5)).to eq(TimeStamp(7, 30))
      end

      it 'parses strings' do
        expect(TimeStamp('8:30')).to eq(TimeStamp(8, 30))
      end

      it 'parses time' do
        time = Time.new(2019, 01, 01, 10, 30)
        expect(TimeStamp(time)).to eq(TimeStamp('10:30'))
      end
    end
  end
end

if !defined?(RSpec) && ARGV.empty? && __FILE__ == $0
  ifponto_client = CachedIFPontoClient.new
  start_time = ifponto_client.start_time(Date.today)
  worked_today = start_time ? Today.new(start_time) : OpenStruct.new(started: 'N/A', ends: 'N/A', worked: 'N/A')
  puts worked_today.worked
  puts '---'
  puts "started #{worked_today.started}"
  puts "ends #{worked_today.ends}"
  puts '---'

  weekdays = Date.today
    .downto(0)
    .lazy
    .reject(&:saturday?).reject(&:sunday?)

  recent = PStoreCacheStore.new.read('recent')&.value || []

  gf_client = CachedGlassFactoryClient.new
  weekdays.drop(1).take(5).each do |date|
    worked = ifponto_client.worked(date)
    worked_gf = gf_client.worked(date)
    puts date.strftime('%d/%m: ') + worked.to_s + ' / ' + worked_gf.to_s
    puts recent.map { |project:, activity:| "--#{project.name} - #{activity.name} | bash=#{__FILE__} param1=--track param2=#{date.strftime('%d/%m/%Y')} param3=#{worked} param4=#{activity.id} terminal=false" }
    puts "--Other... | bash=#{__FILE__} param1=--track param2=#{date.strftime('%d/%m/%Y')} param3=#{worked} terminal=false"
  end
else
  def choose_from(options)
    options_str = options.map { |option| %("#{option.name}") }.join(', ')
    script = %(Tell application "System Events" to choose from list {#{options_str}})
    selected = Open3.capture3('osascript', *['-e', script])
      .first
      .strip
      .force_encoding('UTF-8')

    options.find { |option| option.name == selected }
  end

  def select_activity
    store = PStoreCacheStore.new
    client = GlassFactoryClient.new
    project = choose_from(client.projects)
    choose_from(client.activities(project.id)).tap do |activity|
      recent = store.read('recent')&.value || Set.new
      store.write('recent', recent << { project: project, activity: activity })
    end
  end

  if ARGV[0] == '--track'
    date = Date.strptime(ARGV[1],"%d/%m/%Y")
    worked = TimeStamp(ARGV[2])
    activity_id = ARGV[3] || select_activity.id
    script = 'Tell application "System Events" to display dialog "Quais foram as suas atividades?" default answer ""'
    description = Open3.capture3('osascript', *['-e',script,'-e', 'text returned of result']).first.strip.force_encoding('UTF-8')

    result = GlassFactoryClient.new.track_time(date, worked, description, activity_id)
    alert = result ? 'OK!' : 'Erro'

    Open3.capture3('osascript', *['-e', "display alert \"#{alert}\""])
  end
end
