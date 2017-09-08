HAL_EXISTS := $(shell hal -v)

install-halyard:
	curl -O https://raw.githubusercontent.com/spinnaker/halyard/master/install/stable/InstallHalyard.sh
	sudo bash InstallHalyard.sh -y

update-halyard:
	sudo apt-get --assume-yes update
	sudo apt-get --assume-yes upgrade spinnaker-halyard

setup-halyard:
ifdef HAL_EXISTS
	@echo "HAL Already Installed"
	@echo "Updating HAL"
	make update-halyard
else
	@echo "HAL Not Installed"
	@echo "Installing HAL"
	make install-halyard
endif 