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

class Torchat; module Protocol

define_extension :groupchat do
	define_packet :invite do
		define_unpacker_for 1 .. -1

		attr_reader :id, :modes

		def initialize (id = nil, *modes)
			@id    = id || Torchat.new_cookie
			@modes = modes.flatten.compact.uniq.map(&:to_sym)
		end

		def pack
			super("#{id}#{" #{modes.join ' '}" unless modes.empty?}")
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})#{": #{modes.join ' '}" unless modes.empty?}>"
		end
	end

	define_packet :participants do
		define_unpacker_for 1 .. -1

		attr_accessor :id

		def initialize (id, *participants)
			@id       = id
			@internal = participants.flatten.compact.uniq
		end

		def method_missing (id, *args, &block)
			return @internal.__send__ id, *args, &block if @internal.respond_to? id

			super
		end

		def respond_to_missing? (id, include_private = false)
			@internal.respond_to? id, include_private
		end

		def pack
			super("#{id}#{" #{join ' '}" unless empty?}")
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})#{": #{join ' '}" unless empty?}>"
		end
	end

	define_packet :is_participanting do
		define_unpacker_for 1

		def id
			@internal
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})>"
		end
	end

	define_packet :participating do
		define_unpacker_for 1

		def id
			@internal
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})>"
		end
	end

	define_packet :not_participating do
		define_unpacker_for 1

		def id
			@internal
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})>"
		end
	end

	define_packet :join do
		define_unpacker_for 1

		def id
			@internal
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})>"
		end
	end

	define_packet :leave do
		define_unpacker_for 1 .. 2 do |data|
			id, data = data.split ' ', 2

			[id, data && !data.empty? ? data.force_encoding('UTF-8') : nil]
		end

		attr_accessor :id, :reason

		def initialize (id, reason = nil)
			@id     = id
			@reason = reason
		end

		def pack
			super("#{id}#{" #{reason.encode('UTF-8')}" if reason}")
		end

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id})#{": #{reason.inspect}" if reason}>"
		end
	end

	define_packet :invited do
		define_unpacker_for 2

		attr_accessor :id, :buddy

		def initialize (id, buddy)
			@id    = id
			@buddy = buddy
		end

		def pack
			super("#{id} #{to_s}")
		end

		def to_s
			@buddy
		end

		alias to_str to_s

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id}): #{to_s}>"
		end
	end

	define_packet :message do
		define_unpacker_for 2 do |data|
			id, data = data.split ' ', 2

			[id, data.force_encoding('UTF-8')]
		end

		attr_accessor :id, :content

		def initialize (id, content)
			@id      = id
			@content = content
		end

		def pack
			super("#{id} #{to_s.encode('UTF-8')}")
		end

		def to_s
			@content
		end

		alias to_str to_s

		def inspect
			"#<Torchat::Packet[#{"#{extension}_" if extension}#{type}](#{id}): #{to_s.inspect}>"
		end
	end
end

end; end
