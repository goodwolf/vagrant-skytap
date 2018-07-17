# Copyright (c) 2014-2016 Skytap, Inc.
#
# The MIT License (MIT)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

require 'vagrant-skytap/api/environment'
require 'vagrant-skytap/api/network'
require 'vagrant-skytap/api/vm'

module VagrantPlugins
  module Skytap
    module Action
      # Creates a multi-VM Skytap environment, or adds VMs to an existing
      # environment. The source VMs (analogous to "images") may come from
      # various other environments and templates. We can parallelize this
      # somewhat by adding multiple VMs per REST call, subject to the
      # restriction that all source VMs added in a single call must be unique
      # and must belong to the same containing environment/template.
      # If creating a new environment from scratch, write the environment
      # URL into the project data directory.
      class ComposeEnvironment
        attr_reader :env

        def initialize(app, env)
          @app = app
          @env = env
          @logger = Log4r::Logger.new("vagrant_skytap::action::compose_environment")
        end

        def call(env)
          environment = env[:environment]
          new_environment = !environment
          machines = env[:machines].reject(&:id)
          puts machines.inspect
          environment = add_vms(environment, machines)

          if new_environment
            env[:environment] = environment
            env[:ui].info(I18n.t("vagrant_skytap.environment_url", url: environment.url))
          elsif machines.present?
            env[:ui].info("Added VMs to #{environment.url}.")
          else
            env[:ui].info("No new VMs added to #{environment.url}.")
          end

          @app.call(env)
        end

        # Create Skytap VMs for the given machines (if they do not exist)
        # within the given Skytap environment.
        #
        # @param [API::Environment] environment The Skytap environment, if it exists
        # @param [Array] machines Set of [Vagrant::Machine] objects
        # @return [API::Environment] The new or existing environment
        def add_vms(environment, machines)
          source_vms_map = fetch_source_vms(machines)
          names_to_vm_ids = {}

          get_groupings(source_vms_map, parallel: @env[:parallel]).each do |names|
            vms_for_pass = names.collect{|name| source_vms_map[name]}

            if !environment
              @logger.debug("Creating environment from source vms: #{vms_for_pass.collect(&:id)}")
              environment = API::Environment.create!(env, vms_for_pass)
              environment.properties.write('url' => environment.url)
              vms = environment.vms
            else
              @logger.debug("Adding source vms: #{vms_for_pass.collect(&:id)}")
              vms = environment.add_vms(vms_for_pass)
            end

            vms.each_with_index do |vm, i|
              names_to_vm_ids[names[i]] = vm.id
            end

          end

          machines.each do |machine|
            machine.id = names_to_vm_ids[machine.name]
            vm = API::Vm.fetch(env, "https://cloud.skytap.com/vms/#{machine.id}/")

            vm.set_name(env, machine.provider_config.name) if machine.provider_config.name

            if defined?(machine.provider_config.user_data)
              vm.set_user_data(@env, machine.provider_config.user_data)
            end

            if defined?(machine.provider_config.disks)
              machine.provider_config.disks.each do |k, v|
                new_disk = v.dup
                vm.add_disk(@env, new_disk)
              end
            end

            if machine.provider_config.delete_network_adapters
              vm.delete_interfaces(env)
            end

            if defined?(machine.provider_config.networks)

              machine.provider_config.networks.each do |k,v|
                network_attrs = v[1].dup
                network_attrs.delete(:id)
                network_attrs.delete(:ip)

                @logger.info("Creating new network")
                new_network = environment.add_network(@env, network_attrs)

                @logger.info("Creating a new interface for the vm")
                # Create the network interface for the machine
                new_interface = vm.create_network_interface(env)

                # Attach the network interface to the network
                new_interface.attach_to_network(new_network.id)

                if v[1][:ip]
                  new_interface.attach_private_ip(v[1][:ip])
                end
              end
            end



          end

          environment
        end

        # Fetch the source VMs for the given machines.
        #
        # @param [Array] machines Set of [Vagrant::Machine] objects
        # @return [Hash] mapping of machine names to [API::Vm] objects
        def fetch_source_vms(machines)
          machines.inject({}) do |acc, machine|
            acc[machine.name] = API::Vm.fetch(env, machine.provider_config.vm_url)
            acc
          end
        end

        # Group the machines to minimize calls to the REST API --
        # unique VMs from the same environment or template can be
        # added in a single call. The return value is a nested
        # array of machine names, e.g.:
        # [ [:vm1, :vm4, :vm5], [:vm3], [:vm2] ]
        #
        # However, if the :parallel option is false, just return one
        # machine per grouping, e.g.:
        # [ [:vm1], [:vm2], [:vm3], [:vm4], [:vm5] ]
        #
        # @param [Hash] vms_map Mapping of machine names to [API::Vm] objects
        # @param [Hash] options
        # @return [Array] groupings (arrays) of machine names
        def get_groupings(vms_map, options={})
          parallel = true
          parallel = options[:parallel] if options.has_key?(:parallel)
          return vms_map.keys.collect{|name| [name]} unless parallel

          # Produces nested hash, mapping configuration/template urls to
          # a map of machine names to the source VM id. (We discard the
          # parent urls -- they are just used to group the VMs.)
          groupings = vms_map.inject(Hash.new{|h,k| h[k] = {}}) do |acc, (name, vm)|
            acc[vm.parent_url][name] = vm.id
            acc
          end.values

          groupings2 = []
          groupings.each_with_index do |grouping, i|
            if grouping.values.uniq.count == grouping.values.count
              # The new VMs in the API response will be sorted
              # by the source VM ids. Sort the machines within
              # each group to match.
              groupings2 << grouping.invert.sort.collect(&:last)
            else
              # If the same source VM appears more than once in a
              # group, we have to make multiple API calls. For
              # simplicity, handle this case by creating a single
              # group for each machine.
              groupings2.concat(grouping.keys.map{|v| [v]})
            end
          end

          groupings2.sort_by{|grouping| grouping.count}.reverse
        end
      end
    end
  end
end
