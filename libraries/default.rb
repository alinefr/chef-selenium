def selenium_java_exec
  java = node['selenium']['java']
  validate_exec(%("#{java}" -version))
  java
end

def validate_exec(cmd)
  exec = Mixlib::ShellOut.new(cmd)
  exec.run_command
  exec.error!
end

def selenium_home
  node['selenium']['home']
end

def selenium_jar_link
  "#{selenium_home}/server/selenium-server-standalone.jar"
end

def selenium_windows_service(name, exec, args)
  log_file = "#{selenium_home}/log/#{name}.log"
  nssm name do
    program exec
    args args.join(' ').gsub('"', '"""')
    params(
      AppDirectory: selenium_home,
      AppStdout: log_file,
      AppStderr: log_file,
      AppRotateFiles: 1
    )
    action :install
  end
end

# http://sqa.stackexchange.com/a/6267
def selenium_windows_gui_service(name, exec, args, username)
  args << %(-log "#{selenium_home}/log/#{name}.log")
  cmd = "#{selenium_home}/bin/#{name}.cmd"

  file cmd do
    content %("#{exec}" #{args.join(' ')})
    action :create
    notifies :request, "windows_reboot[Reboot to start #{name}]"
  end

  startup_path = "C:\\Users\\#{username}\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"

  ruby_block 'hack to mkdir on windows' do
    block do
      FileUtils.mkdir_p startup_path
    end
  end

  windows_shortcut "#{startup_path}\\#{name}.lnk" do
    target cmd
    cwd selenium_home
    action :create
  end
end

def selenium_windows_firewall(name, port)
  execute "Firewall rule #{name} for port #{port}" do
    command "netsh advfirewall firewall add rule name=\"#{name}\" protocol=TCP dir=in profile=any"\
      " localport=#{port} remoteip=any localip=any action=allow"
    action :run
    not_if "netsh advfirewall firewall show rule name=\"#{name}\" > nul"
  end
end

def windows_domain(username)
  '\\'.include?(username) ? username.split('\\').first : nil
end

def windows_user(username)
  '\\'.include?(username) ? username.split('\\').last : username
end

def selenium_autologon(username, password)
  case node['platform_family']
  when 'windows'
    # TODO: REPLACE WITH windows_autologin cookbook
    registry_key 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' do
      values [
        { name: 'AutoAdminLogon', type: :string, data: '1' },
        { name: 'DefaultUsername', type: :string, data: windows_user(username) },
        { name: 'DefaultPassword', type: :string, data: password },
        { name: 'DefaultDomainName', type: :string, data: windows_domain(username) }
      ]
      action :create
    end
  when 'mac_os_x'
    node.override['macosx_autologin']['username'] = username
    node.override['macosx_autologin']['password'] = password
    recipe_eval do
      run_context.include_recipe 'macosx_autologin::default'
    end
  end
end

def selenium_systype
  return 'systemd' if ::File.exist?('/proc/1/comm') && ::File.open('/proc/1/comm').gets.chomp == 'systemd'
  return 'upstart' if platform?('ubuntu') && ::File.exist?('/sbin/initctl')
  'sysvinit'
end

def selenium_linux_service(name, exec, args, port, display)
  # TODO: make selenium username default and pass it in as a param
  username = 'selenium'

  user "ensure user #{username} exits for #{name}" do
    username username
    manage_home true
    shell '/bin/bash'
    home "/home/#{username}"
    system true
  end

  systype = selenium_systype
  if systype == 'systemd'
    path = "/etc/systemd/system/#{name}.service"
    formatted_args = args.join(' ')
  else
    path = "/etc/init.d/#{name}"
    formatted_args = args.join(' ').gsub('"', '\"')
  end

  template path do
    source "#{systype}.erb"
    cookbook 'selenium'
    mode '0755'
    variables(
      name: name,
      user: username,
      exec: exec,
      args: formatted_args,
      port: port,
      display: display
    )
    notifies :restart, "service[#{name}]"
  end

  service name do
    supports restart: true, reload: true, status: true
    action [:enable, :start]
  end
end

def selenium_mac_service(name, exec, args, plist, username)
  execute "reload #{name}" do
    command "launchctl unload -w #{plist}; launchctl load -w #{plist}"
    user username
    action :nothing
    returns [0, 112] # 112 not logged into gui
  end

  directory '/var/log/selenium' do
    mode '0755'
  end

  file "/var/log/selenium/#{name}.log" do
    mode '0664'
    user username
    action :touch
  end

  template plist do
    source 'org.seleniumhq.plist.erb'
    cookbook 'selenium'
    mode '0755'
    variables(
      name: name,
      exec: exec,
      args: args
    )
    notifies :run, "execute[reload #{name}]", :immediately
    notifies :run, "execute[Reboot to start #{name}]" if username # assume node
  end
end

def selenium_mac_domain(name)
  "org.seleniumhq.#{name}"
end
