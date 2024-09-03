#!/bin/bash

set -e
set -x

# https://jekyll-theme-gungnir.vercel.app/theme/

sudo apt install -y ruby-full build-essential zlib1g-dev

# echo '# Install Ruby Gems to ~/gems' >> ~/.bashrc
# echo 'export GEM_HOME="$HOME/gems"' >> ~/.bashrc
# echo 'export PATH="$HOME/gems/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

gem install jekyll bundler

bundle config set path 'vendor/bundle'
bundle install
