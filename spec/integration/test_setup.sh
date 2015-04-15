#!/bin/bash

export BEAKER_setfile=nodesets/rhel7.yaml
export PKG_VERSION=1.0.0-b20124-13673734

bundle exec rspec integration_1_spec.rb
