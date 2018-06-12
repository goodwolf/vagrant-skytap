# Copyright (c) 2014-2018 Skytap, Inc.
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

module VagrantPlugins
  module Skytap
    module Util
      module VM
        class << self
          # Validates a set of VMs can be used together in a REST call to
          # create a new environment, or to add to an existing environment.
          #
          # @param [Array] vms The [API::Vm] objects to validate
          # @param [API::Environment] environment to validate against (optional)
          # @return [Boolean] strue, if no exceptions were raised
          def check_vms_before_adding(vms, environment = nil)
            vms.each do |vm|
              raise Errors::SourceVmNotStopped, url: vm.url unless vm.stopped?
            end

            raise Errors::VmParentMismatch, vm_ids: vms.collect(&:id).join(', ') unless vms.collect(&:parent_url).uniq.count == 1

            if environment
              parent = vms.first.parent
              unless parent.region == environment.region
                raise Errors::RegionMismatch, environment_region: environment.region, vm_region: parent.region
              end
            end
            true
          end
        end
      end
    end
  end
end