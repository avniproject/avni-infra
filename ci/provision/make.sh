if make -v; then
    echo "make Installed"
else
    echo "make Not Installed"
    echo "Installing make"
    sudo apt-get install --reinstall make
fi