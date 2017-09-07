if hal -v; then
    sudo apt-get update
    sudo apt-get upgrade spinnaker-halyard
else
    curl -O https://raw.githubusercontent.com/spinnaker/halyard/master/install/stable/InstallHalyard.sh
    sudo bash InstallHalyard.sh
fi