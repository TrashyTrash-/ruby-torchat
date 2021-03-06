#--
# Copyleft meh. [http://meh.schizofreni.co | meh@schizofreni.co]
#
# This file is part of torchat for ruby.
#
# torchat for ruby is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# torchat for ruby is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with torchat for ruby. If not, see <http://www.gnu.org/licenses/>.
#++

require 'em-socksify'

class Torchat; class Session

class Outgoing < EventMachine::Protocols::LineAndTextProtocol
	include EM::Socksify

	attr_accessor :owner

	def post_init
		@delayed = []
	end

	def connection_completed
		old, new = comm_inactivity_timeout, @session.connection_timeout

		set_comm_inactivity_timeout new

		@session.fire :connect_to, address: @owner.address, port: @owner.port

		socksify(@owner.address, @owner.port).callback {
			set_comm_inactivity_timeout old

			@owner.connected
		}.errback {|exc|
			Torchat.debug exc, level: 3

			@owner.disconnect
		}
	end

	def verification_completed
		@delayed.each {|packet|
			send_packet! packet
		}

		@delayed = nil
	end

	def receive_line (line)
		packet = Protocol.unpack(line.chomp, @owner)
		
		return unless packet.type.to_s.start_with 'file'

		@owner.session.received_packet packet
	end

	def send_packet (*args)
		packet = Protocol.packet(*args)

		if @delayed
			@delayed << packet
		else
			send_packet! packet
		end

		packet
	end

	def send_packet! (*args)
		packet = Protocol.packet(*args)

		Torchat.debug ">> #{@owner ? @owner.id : 'unknown'} #{packet.inspect}", level: 2

		send_data packet.pack

		packet
	end

	def unbind
		if error?
			Torchat.debug "errno #{EM.report_connection_error_status(@signature)}", level: 2
		end

		if @owner.connecting?
			@owner.failed!
		else
			@owner.disconnect
		end
	end
end

end; end
