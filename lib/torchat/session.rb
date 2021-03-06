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

require 'eventmachine'

require 'torchat/session/event'
require 'torchat/session/buddies'
require 'torchat/session/file_transfers'
require 'torchat/session/group_chats'
require 'torchat/session/broadcasts'

class Torchat

class Session
	attr_reader   :config, :id, :name, :description, :status, :buddies, :file_transfers, :group_chats, :broadcasts
	attr_writer   :client, :version
	attr_accessor :connection_timeout

	def initialize (config)
		@config = config

		@status = :offline

		@id          = @config['id'][/^(.*?)(\.onion)?$/, 1]
		@name        = config['name']
		@description = config['description']

		@buddies        = Buddies.new(self)
		@file_transfers = FileTransfers.new(self)
		@group_chats    = GroupChats.new(self)
		@broadcasts     = Broadcasts.new(self)

		@callbacks = Hash.new { |h, k| h[k] = [] }
		@before    = Hash.new { |h, k| h[k] = [] }
		@after     = Hash.new { |h, k| h[k] = [] }
		@timers    = []

		@connection_timeout = 60

		on :unknown do |e|
			e.buddy.send_packet :not_implemented, e.line.split(' ').first
		end

		on :verify do |e|
			# this actually gets executed only if the buddy doesn't exist
			# so we can still check if the buddy is permanent below
			buddies.add_temporary e.buddy

			e.buddy.send_packet :client,  client
			e.buddy.send_packet :version, version
			e.buddy.send_packet :supports, Protocol.extensions.map(&:name)

			e.buddy.send_packet :profile_name, name        if name
			e.buddy.send_packet :profile_text, description if description

			if e.buddy.permanent?
				e.buddy.send_packet :add_me
			end

			e.buddy.send_packet :status, status
		end

		on_packet :supports do |e|
			e.buddy.supports *e.packet.to_a
		end

		on_packet :status do |e|
			next if e.buddy.ready?

			e.buddy.ready!

			fire :ready, buddy: e.buddy
		end

		on_packet :add_me do |e|
			e.buddy.permanent!
		end

		on_packet :remove_me do |e|
			buddies.remove e.buddy

			e.buddy.disconnect
		end

		on_packet :client do |e|
			e.buddy.client.name = e.packet.to_str
		end

		on_packet :version do |e|
			e.buddy.client.version = e.packet.to_str
		end

		on_packet :status do |e|
			old = e.buddy.status

			if old != e.packet.to_sym
				e.buddy.status = e.packet.to_sym

				fire :status_change, buddy: e.buddy, old: old, new: e.packet.to_sym
			end
		end

		on_packet :profile_name do |e|
			e.buddy.name = e.packet.to_str

			fire :profile_change, buddy: e.buddy, changed: :name
		end

		on_packet :profile_text do |e|
			e.buddy.description = e.packet.to_str

			fire :profile_change, buddy: e.buddy, changed: :description
		end

		on_packet :profile_avatar_alpha do |e|
			e.buddy.avatar.alpha = e.packet.data
		end

		on_packet :profile_avatar do |e|
			e.buddy.avatar.rgb = e.packet.data

			fire :profile_change, buddy: e.buddy, changed: :avatar
		end

		on_packet :message do |e|
			fire :message, buddy: e.buddy, message: e.packet.to_str
		end

		on_packet :filename do |e|
			file_transfers.receive(e.packet.id, e.packet.name, e.packet.size, e.buddy)
		end

		on_packet :filedata do |e|
			next unless file_transfer = file_transfers[e.packet.id]

			file_transfer.add_block(e.packet.offset, e.packet.data, e.packet.md5).valid?
		end

		on_packet :filedata_ok do |e|
			next unless file_transfer = file_transfers[e.packet.id]

			file_transfer.send_next_block
		end

		on_packet :filedata_error do |e|
			next unless file_transfer = file_transfers[e.packet.id]

			file_transfer.send_last_block
		end

		on_packet :file_stop_sending do |e|
			next unless file_transfer = file_transfers[e.packet.id]

			file_transfer.stop(true)
		end

		on_packet :file_stop_receiving do |e|
			next unless file_transfer = file_transfers[e.packet.id]

			file_transfer.stop(true)
		end

		set_interval 120 do
			next unless online?

			buddies.each_value {|buddy|
				next unless buddy.online?

				if (Time.new.to_i - buddy.last_received.at.to_i) >= 360
					buddy.disconnect
				else
					buddy.send_packet :status, status
				end
			}
		end

		set_interval 10 do
			next unless online?

			buddies.each_value {|buddy|
				next if buddy.online? || buddy.blocked?

				next if (Time.new.to_i - buddy.last_try.to_i) < ((buddy.tries > 36 ? 36 : buddy.tries) * 10)

				buddy.connect
			}
		end

		# typing extension support
		on_packet :typing_start do |e|
			e.buddy.typing!
		end

		on_packet :typing_thinking do |e|
			e.buddy.thinking!
		end

		on_packet :typing_stop do |e|
			e.buddy.not_typing!
		end

		on_packet :message do |e|
			e.buddy.not_typing!
		end

		# groupchat extension support
		on_packet :groupchat, :invite do |e|
			next if group_chats.has_key? e.packet.id

			group_chat = group_chats.create(e.packet.id, false)
			group_chat.invited_by e.buddy
			group_chat.add e.buddy

			fire :group_chat_invite, group_chat: group_chat, buddy: e.buddy
		end

		on_packet :groupchat, :is_participating do |e|
			if group_chats[e.packet.id]
				e.buddy.send_packet [:groupchat, :participating]
			else
				e.buddy.send_packet [:groupchat, :not_participating]
			end
		end

		on_packet :groupchat, :participants do |e|
			next unless group_chat = group_chats[e.packet.id] and !group_chat.joining?

			participants = group_chat.participants.keys - e.packet.to_a
			participants.reject! { |p| p == id || p == e.buddy.id }

			e.buddy.send_packet [:groupchat, :participants], group_chat.id, participants
		end

		on_packet :groupchat, :participants do |e|
			next unless group_chat = group_chats[e.packet.id] and group_chat.joining? and group_chat.invited_by == e.buddy

			if e.packet.empty?
				group_chat.joined!

				next
			end
			
			if e.packet.any? { |id| buddies.has_key?(id) && buddies[id].blocked? }
				group_chat.leave

				next
			end

			if e.packet.all? { |id| buddies.has_key?(id) && buddies[id].online? }
				e.packet.each {|id|
					group_chat.add buddies[id]
				}

				e.buddy.send_packet [:groupchat, :participants], group_chat.id, group_chat.participants.keys

				next
			end

			e.packet.each {|p|
				next if (buddy = buddies.add_temporary(p)).online?

				buddy.when :ready do
					buddy.send_packet [:groupchat, :is_participating], group_chat.id

					participating = buddy.on_packet :groupchat, :participating do |e|
						next if group_chat.left?

						group_chat.add e.buddy

						if e.packet.all? { |id| buddies[id].online? }
							e.buddy.send_packet [:groupchat, :participants], group_chat.id, group_chat.participants.keys
						end
					end

					not_participating = buddy.on_packet :groupchat, :not_participating do |e|
						group_chat.leave
					end

					# avoid possible memory leak, I don't do this inside both callbacks
					# because a bad guy could not send either of those packets and there
					# would be a leak anyway
					set_timeout 10 do
						participating.remove!
						not_participating.remove!
					end

					e.remove!
				end
			}
		end

		on_packet :groupchat, :invited do |e|
			next unless group_chat = group_chats[e.packet.id]

			unless (buddy = buddies[e.packet.to_s]) && buddy.online?
				buddy = buddies.add_temporary(e.packet.to_s)

				buddy.on :ready do |e|
					group_chat.add buddy, e.buddy

					fire :group_chat_join, group_chat: group_chat, buddy: buddy, invited_by: e.buddy

					e.remove!
				end
			else
				group_chat.add buddy, e.buddy

				fire :group_chat_join, group_chat: group_chat, buddy: buddy, invited_by: e.buddy
			end
		end

		on_packet :groupchat, :join do |e|
			next unless group_chat = group_chats[e.packet.id]

			group_chat.add e.buddy

			group_chat.participants.each_value {|participant|
				next if participant.id == e.buddy.id

				participant.send_packet [:groupchat, :invited], group_chat.id, e.buddy.id
			}

			fire :group_chat_join, group_chat: group_chat, buddy: e.buddy
		end

		on_packet :groupchat, :leave do |e|
			next unless group_chat = e.buddy.group_chats[e.packet.id]

			group_chat.leave e.packet.reason
		end

		on_packet :groupchat, :message do |e|
			next unless group_chat = group_chats[e.packet.id]

			fire :group_chat_message, group_chat: group_chat, buddy: e.buddy, message: e.packet.to_str
		end

		before :disconnect do |e|
			e.buddy.group_chats.each_value {|group_chat|
				group_chat.leave
			}
		end

		after :group_chat_leave do |e|
			if e.group_chat.empty? && group_chats.has_key?(e.group_chat.id)
				group_chats.destroy e.group_chat.id
			end
		end

		# broadcast support
		on_packet :broadcast, :message do |e|
			broadcasts.received e.packet.to_str
		end

		# latency support
		on_packet :latency, :ping do |e|
			e.buddy.send_packet [:latency, :pong], e.packet.id
		end

		on_packet :latency, :pong do |e|
			e.buddy.latency.pong(e.packet.id)

			fire :latency, buddy: e.buddy, amount: e.buddy.latency.to_f, id: e.packet.id
		end

		yield self if block_given?
	end

	def address
		"#{id}.onion"
	end

	def client
		@client || 'ruby-torchat'
	end
	
	def version
		@version || Torchat.version
	end

	def tor
		Struct.new(:host, :port).new(
			@config['connection']['outgoing']['host'],
			@config['connection']['outgoing']['port'].to_i
		)
	end

	def name= (value)
		@name = value

		buddies.each_value {|buddy|
			next unless buddy.online?

			buddy.send_packet :profile_name, value
		}
	end

	def description= (value)
		@description = value

		buddies.each_value {|buddy|
			next unless buddy.online?

			buddy.send_packet :profile_text, value
		}
	end

	def offline?; @status == :offline; end
	def online?;  !offline?;           end

	def online!
		return if online?

		@status = :available

		buddies.each_value {|buddy|
			buddy.connect
		}
	end

	def offline!
		return if offline?

		@status = :offline

		buddies.each_value {|buddy|
			buddy.disconnect
		}
	end

	def status= (value)
		if value.to_sym.downcase == :offline
			offline!; return
		end

		online! if offline?

		unless Protocol[:status].valid?(value)
			raise ArgumentError, "#{value} is not a valid status"
		end

		@status = value.to_sym.downcase

		buddies.each_value {|buddy|
			next unless buddy.online?

			buddy.send_packet :status, @status
		}
	end

	def on (what, &block)
		what = what.to_sym.downcase

		@callbacks[what] << block

		Event::Removable.new(self, what, &block)
	end

	def on_packet (*args, &block)
		if args.length == 2
			extension, name = args
		else
			extension, name = nil, args.first
		end

		if name
			on :packet do |e|
				block.call e if e.packet.type == name && e.packet.extension == extension
			end
		else
			on :packet, &block
		end
	end

	def before (what = nil, &block)
		what = what.to_sym.downcase if what

		@before[what] << block

		Event::Removable.new(self, what, :before, &block)
	end

	def after (what = nil, &block)
		what = what.to_sym.downcase if what

		@after[what] << block

		Event::Removable.new(self, what, :after, &block)
	end

	def remove_callback (chain = nil, name = nil, block)
		if block.is_a? Event::Removable
			chain = block.chain
			name  = block.name
			block = block.block
		end

		if name && chain
			if chain == :before
				@before[name]
			elsif chain == :after
				@after[name]
			else
				@callbacks[name]
			end.delete(block)
		else
			[@before[nil], @before[name], @callbacks[name], @after[name], @after[nil]].each {|callbacks|
				callbacks.each {|callback|
					if callback == block
						callbacks.delete(callback)

						return
					end
				}
			}
		end
	end

	def received_packet (packet)
		fire :packet, packet: packet, buddy: packet.from
	end

	def fire (name, data = nil, &block)
		name  = name.downcase.to_sym
		event = Event.new(self, name, data, &block)

		[@before[nil], @before[name], @callbacks[name], @after[name], @after[nil]].each {|callbacks|
			callbacks.each {|callback|
				begin
					callback.call event
				rescue => e
					Torchat.debug e
				end

				if event.remove?
					remove_callback(callback)
					event.removed!
				end
				
				return if event.stopped?
			}
		}
	end

	def start (host = nil, port = nil)
		host ||= @config['connection']['incoming']['host']
		port ||= @config['connection']['incoming']['port'].to_i

		@signature = EM.start_server host, port, Incoming do |incoming|
			incoming.instance_variable_set :@session, self
		end
	end

	def stop
		EM.stop_server @signature

		@timers.each {|timer|
			EM.cancel_timer(timer)
		}
	end

	def set_timeout (*args, &block)
		EM.schedule {
			EM.add_timer(*args, &block).tap {|timer|
				@timers.push(timer)
			}
		}
	end

	def set_interval (*args, &block)
		EM.schedule {
			EM.add_periodic_timer(*args, &block).tap {|timer|
				@timers.push(timer)
			}
		}
	end

	def clear_timeout (what)
		EM.schedule {
			EM.cancel_timer(what)
		}
	end

	alias clear_interval clear_timeout
end

end
