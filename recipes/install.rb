require 'securerandom'

directory "#{node['cloud']['init']['install_dir']}/ec2init" do
  owner "root"
  group "root"
  mode "700"
end

directory node['data']['dir'] do
  owner 'root'
  group 'root'
  mode '0775'
  action :create
  not_if { ::File.directory?(node['data']['dir']) }
end

directory node['cloud']['data_volume']['root_dir'] do
  owner 'root'
  group 'root'
  mode '0770'
  action :create
end

directory node['cloud']['data_volume']['ec2init_checks'] do
  owner 'root'
  group 'root'
  mode '0770'
  action :create
end

link "#{node['cloud']['init']['install_dir']}/ec2init/ec2init_checks" do
  owner 'root'
  group 'root'
  mode '0770'
  to node['cloud']['data_volume']['ec2init_checks']
end

file "#{node['cloud']['data_volume']['root_dir']}/ec2init.log" do
  content ''
  owner 'root'
  group 'root'
  mode "750"
  action :create
  not_if { File.exist?("#{node['cloud']['data_volume']['root_dir']}/ec2init.log") }
end

link "#{node['cloud']['init']['install_dir']}/ec2init/ec2init.log" do
  owner 'root'
  group 'root'
  mode '0750'
  to "#{node['cloud']['data_volume']['root_dir']}/ec2init.log"
end

template "#{node['cloud']['init']['install_dir']}/ec2init/run_ec2_init.sh" do
    source "run_ec2_init.sh.erb"
    user "root"
    group "root"
    mode 0500
end

template "#{node['cloud']['init']['install_dir']}/ec2init/run_ec2_update.sh" do
    source "run_ec2_update.sh.erb"
    user "root"
    group "root"
    mode 0500
end

template "#{node['cloud']['init']['install_dir']}/ec2init/deploy2glassfish_hook.sh" do
  source "deploy2glassfish_hook.sh.erb"
  user "root"
  group "root"
  mode 0500
end

template "#{node['cloud']['init']['install_dir']}/ec2init/ec2init_config.ini" do
  source "ec2init_config.ini.erb"
  user "root"
  group "root"
  mode 0500
end

cached_file = "ec2init-#{node['cloud']['init']['version']}-py3-none-any.whl"
source = "#{node['install']['enterprise']['download_url']}/ec2init/#{node['cloud']['init']['version']}/#{cached_file}"
remote_file "#{Chef::Config['file_cache_path']}/#{cached_file}" do
  user 'root'
  group 'root'
  source source
  headers get_ee_basic_auth_header()
  sensitive true
  mode 0555
  action :create_if_missing
end

cached_file = "requirements.txt"
source = "#{node['install']['enterprise']['download_url']}/ec2init/#{node['cloud']['init']['version']}/requirements.txt"
remote_file "#{Chef::Config['file_cache_path']}/ec2init-requirements.txt" do
  user 'root'
  group 'root'
  source source
  headers get_ee_basic_auth_header()
  sensitive true
  mode 0555
end

case node["platform_family"]
when "debian"
  bash "add certbot repository" do
    user "root"
    group "root"
    code <<-EOF
      apt-get update
      apt-get install -y software-properties-common
      add-apt-repository -y universe
      apt-get update
    EOF
  end
  systemd_directory = "/lib/systemd/system"
  os_flavour = "ubuntu"

  package ["build-essential", "libssl-dev", "zlib1g-dev", "libffi-dev", "libbz2-dev", "libreadline-dev", "liblzma-dev"] do
    retries 10
    retry_delay 30
  end

when "rhel"
  systemd_directory = "/usr/lib/systemd/system"
  os_flavour = "centos"

  package ["epel-release", "gcc", "gcc-c++", "openssl", "openssl-devel", "openssl-libs", "libffi-devel", "bzip2-devel", "readline-devel", "xz-devel"] do
    retries 10
    retry_delay 30
  end
  
end

filename = File.basename(node['cloud']['cloudwatch']['download_url'][os_flavour])
cached_file = "#{Chef::Config['file_cache_path']}/#{filename}"
remote_file cached_file do
  source node['cloud']['cloudwatch']['download_url'][os_flavour]
  user 'root'
  group 'root'
  mode 0500
  action :create
  only_if { node['cloud']['collect_logs'].casecmp?("true") && node['install']['cloud'].casecmp?("aws")}
end

bash 'Install pyenv' do
  user 'root'
  group 'root'
  code <<-EOH
    set -e
    curl https://pyenv.run | bash
    echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
    echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(pyenv init -)"' >> ~/.bashrc
  EOH
  not_if { ::File.exists?("/root/.pyenv") }
end

bash 'Install Python 3.11' do
  user 'root'
  group 'root'
  environment ({'PYENV_ROOT' => '/root/.pyenv'})
  code <<-EOH
    set -e
    export PATH=$PYENV_ROOT/bin:$PATH
    eval "$(pyenv init -)"
    set +e
    pyenv shims --short | grep python3.11
    r=$?
    set -e
    if [[ "$r" -ne 0 ]]; then
      pyenv install 3.11
    fi
    pyenv shell 3.11
    pip install virtualenv
  EOH
end

# We can't just use package because in Ubuntu package provider cannot
# install a deb package from source, we must use dpkg_package provider
case node['platform_family']
when 'debian'
  dpkg_package "amazon-cloudwatch-agent" do
    retries 10
    retry_delay 30
    source cached_file
    action :install
    only_if { ::File.exist?(cached_file) }
  end
  package ["python3-virtualenv"] do
    retries 10
    retry_delay 30
  end
when 'rhel'
  package "amazon-cloudwatch-agent" do
    retries 10
    retry_delay 30
    source cached_file
    action :install
    only_if { ::File.exist?(cached_file) }
  end
  
  package ["snapd" ] do
    retries 10
    retry_delay 30
  end

  bash 'configure-snapd' do
    user 'root'
    group 'root'
    code <<-EOH
      set -e
      systemctl enable --now snapd.socket
      # enable classic snap support
      [[ -e /snap ]] || ln -s /var/lib/snapd/snap /snap
    EOH
  end
end

package ["curl", "unzip"] do
  retries 10
  retry_delay 30
end

bash 'install-certbot' do
  user 'root'
  group 'root'
  code <<-EOH
    set -e
    # Although we execute as root, for Centos it is safer
    # to run sudo because we have just installed snap above
    # and we need to login to initialize it
    sudo snap install core; sudo snap refresh core
    sudo snap install --classic certbot
    [[ -e /usr/bin/certbot ]] || ln -s /snap/bin/certbot /usr/bin/certbot
  EOH
end

template "#{systemd_directory}/ec2update.service" do
  source "ec2update.service.erb"
  owner "root"
  group "root"
  mode 0664
end

if node['cloud']['init']['config']['unmanaged'].casecmp?("true")
  template "#{node['cloud']['init']['install_dir']}/ec2init/unmanaged_ec2init.sh" do
    source "unmanaged_ec2init.sh.erb"
    user 'root'
    group 'root'
    mode 0500
    variables({
      :nonce => SecureRandom.hex[0...10]
    })
  end
  
  template "#{systemd_directory}/unmanaged-ec2init.service" do
    source "unmanaged-ec2init.service.erb"
    owner "root"
    group "root"
    mode 0664
  end
end

template "#{node['cloud']['init']['install_dir']}/ec2init/import_glassfish_internal_x509.sh" do
    source "import_glassfish_internal_x509.sh.erb"
    user 'root'
    group 'root'
    mode 0500
end