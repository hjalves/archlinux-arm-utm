# Arch Linux ARM on UTM, from the local box built with package-box.sh.
#   vagrant up        create and boot
#   vagrant ssh       log in as vagrant (passwordless sudo)
#   vagrant halt      shut down
#   vagrant destroy   delete the VM (the box stays)

Vagrant.configure("2") do |config|
  config.vm.box = "local/arch"
  config.vm.hostname = "arch"

  # The default /vagrant share uses VirtFS (9p). It's off until the box has
  # been tested with it; set disabled: false to try it.
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # config.vm.network "forwarded_port", guest: 80, host: 8080

  config.vm.provider "utm" do |u|
    u.name   = "arch-vagrant"
    u.cpus   = 2
    u.memory = 2048
    u.icon   = "arch-linux"
    u.notes  = "Managed by Vagrant (ClaudeArch/vagrant)"
  end

  # config.vm.provision "shell", inline: <<-SHELL
  #   pacman -Syu --noconfirm
  # SHELL
end
