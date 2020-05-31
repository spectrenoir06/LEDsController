local socket = require("socket")
local class = require("middleclass")
local brotli
local bit
local bxor

if type(jit) == "table" then
	bit = require("bit")
	bxor = bit.bxor
end

local path = ...

local status, brotli = pcall(require, "brotli")
if not status then
	print("Can't load brotli")
end

local upack = nil
local pack   = nil
local gsub = string.gsub

if love then
	pack  = function(format, ...)
		format = gsub(format, "A", "z")
		format = gsub(format, "b", "B")
		format = gsub(format, "c", "b")
		return love.data.pack("string", format, ...)
	end
	upack = function(datastring, format, pos) return 0, love.data.unpack(format, datastring, pos) end
else
	local lpack = require("pack")
	pack = string.pack
	upack = string.unpack
end

local UDP_PORT           = 6454
local MAX_UPDATE_SIZE    = 1280 -- max 1280 after the driver explode == 426 RGB LEDs
local LEDS_BY_UNI        = 170


local ART_POLL           = 0x2000
local ART_REPLY          = 0x2100
local ART_DMX            = 0x5000
local ART_SYNC           = 0x5200
local ARTNET_VERSION     = 0x0E00
local ART_HEAD           = love and "Art-Net" or "Art-Net\0"


local LED_RGB_888        = 0
local LED_RGB_888_UPDATE = 1

local LED_RGB_565        = 2
local LED_RGB_565_UPDATE = 3

local LED_RLE_888        = 11
local LED_RLE_888_UPDATE = 12
local LED_BRO_888        = 13
local LED_BRO_888_UPDATE = 14
local LED_Z_888          = 15
local LED_Z_888_UPDATE   = 16

local LED_UPDATE         = 4
local GET_INFO           = 5
local LED_TEST           = 6
local LED_RGB_SET        = 7
local LED_LERP           = 8
local SET_MODE           = 9
local REBOOT             = 10



local LEDsController = class("LEDsController")

function LEDsController:initialize(t)
	self.led_nb = t.led_nb
	self.ip = t.ip
	self.port = t.remote_port or UDP_PORT
	self.debug = t.debug or false
	self.count = 0
	self.rgbw = t.rgbw
	self.bright = t.bright or 0.1
	self.rgbw_mode = t.rgbw_mode or 0

	if t.protocol == "BRO888" and not brotli then
		t.protocol = "RGB888"
	end

	if t.protocol == "Z888" and not love then
		t.protocol = "RGB888"
	end

	self.protocols = {
		artnet = self.sendArtnetDMX_ext,
		artnet_big = self.sendAllArtnetDMX,
		RGB888 = self.sendAll888,
		RGB565 = self.sendAll565,
		RLE888 = self.sendAllRLE888,
		BRO888 = self.sendAllBRO888,
		Z888   = self.sendAllZ888,
		UDPX   = self.sendAllUDPX,
		UDPX565= self.sendAllUDPX565,
	}


	if t.udp then
		self.udp = t.udp
	else
		self.udp = assert(socket.udp())
		assert(self.udp:setsockname("0.0.0.0", self.port))
		self.udp:settimeout(0)
		self.udp:setoption("broadcast", true)
	end

	self.protocol = self.protocols[t.protocol] or self.sendAllArtnetDMX
	-- print(t.protocol, self.protocols.RLE888, self.protocol )

	self.leds_by_uni = t.leds_by_uni or LEDS_BY_UNI

	self.leds = {}
	for i=1, self.led_nb do self.leds[i] = {0,0,0,0} end

	self.map = t.map
	self.uni = t.uni or 0
	self.net = t.net or 0

	-- print("LEDs controller start using "..self.protocol.." protocol")
end

-------------------------------------------------------------------------------


function LEDsController:printD(...)
	if self.debug then print(...) end
end

local function hex_dump(buf)
	for i=1,math.ceil(#buf/16) * 16 do
		if (i-1) % 16 == 0 then io.write(string.format('%08X  ', i-1)) end
		io.write( i > #buf and '   ' or string.format('%02X ', buf:byte(i)) )
		if i %  8 == 0 then io.write(' ') end
		if i % 16 == 0 then io.write( buf:sub(i-16+1, i):gsub('%c','.'), '\n' ) end
	end
end


--------------------------------- ART-NET -------------------------------------

function LEDsController:sendArtnetDMX(net, sub_uni, off)
	self:printD("ART-NET DMX:", net, sub_uni, off)
	local to_send = pack(
		"AHHbbbb>H",
		ART_HEAD,
		ART_DMX,
		ARTNET_VERSION,
		self.count%256,
		0,
		sub_uni,
		net,
		self.leds_by_uni*3
	)
	self.count = self.count + 1
	local data = self.leds
	local ctn = 0
	local size = self.leds_by_uni
	local mode = self.rgbw and "bbbb" or "bbb"
	local mode_s = self.rgbw and 4 or 3
	for i=1, size do
		local d = data[off*size+i]
		to_send = to_send..pack(
			mode,
			d and d[1] or 0,
			d and d[2] or 0,
			d and d[3] or 0,
			d and d[4] or 0
		)
		ctn = ctn + mode_s
	end

	self.udp:sendto(to_send, self.ip, self.port)
end


function LEDsController:sendArtnetDMX_ext(nb_led, update, delay, ctn)
	self:printD("ART-NET ext DMX:")
	local to_send = pack(
		"AHHbbbb>H",
		ART_HEAD,
		ART_DMX,
		ARTNET_VERSION,
		ctn%256,
		0,
		self.uni,
		self.net,
		self.leds_by_uni*3
	)
	local data = self.leds
	local size = self.leds_by_uni
	local mode = self.rgbw and "bbbb" or "bbb"
	local mode_s = self.rgbw and 4 or 3
	for i=1, size do
		local d = data[i]
		to_send = to_send..pack(
			mode,
			d and d[1] or 0,
			d and d[2] or 0,
			d and d[3] or 0,
			d and d[4] or 0
		)
	end
	self.udp:sendto(to_send, self.ip, self.port)
	if delay then
		socket.sleep(delay)
	end
end

function LEDsController:sendArtnetSync()
	self:printD("ART-NET Sync")
	local to_send = pack(
		"AHHH",
		ART_HEAD,
		ART_SYNC,
		ARTNET_VERSION,
		0x0000
	)
	self.udp:sendto(to_send, "255.255.255.255", self.port)
end

function LEDsController:sendAllArtnetDMX(nb_led, update, delay)
	-- local max_update = math.floor(512 / (self.rgbw and 4 or 3))
	local nb_update = math.ceil(nb_led / self.leds_by_uni)
	if update then
		delay = delay / (nb_update+1)
	else
		delay = delay / nb_update
	end
	self:printD("#artnet", nb_led, nb_update+(update and 1 or 0))
	for i=0, nb_update-1 do
		self:sendArtnetDMX(self.net, self.uni+i, i)
		if delay then
			socket.sleep(delay)
		end
	end
	if update then
		self:sendArtnetSync()
		if delay then
			socket.sleep(delay)
		end
	end
end

function LEDsController:decodeArtnetDMX(data)
	local _,_,_,_,seq,_,uni,net,size = upack(data, "zHHbbbb>H")
	-- if input[net] == nil then input[net] = {} end
	-- input[net][(uni.."")] = data:sub(19)
	print(uni,net,seq)
	local dmx = data:sub(19)
	local data = self.leds
	for i=1,LEDS_BY_UNI do
		local _,r,g,b = upack(dmx, "bbb")
		data[i+(uni*LEDS_BY_UNI)] = {r,g,b}
		dmx = dmx:sub(4)
	end
	return uni,net,seq
end

local function str(s,size)
	local s_size = s:len()
	if s_size < size then
		for i=1,size-s_size do
			s = s .. "\0"
		end
	end
	return s
end

function LEDsController:sendArtnetPollReply(ip, port)
	for i=1,24 do
			local to_send = pack(
			"AHb4HHbbHbbHAAAHI5b7Ab4bbA",
			ART_HEAD,
			ART_REPLY, -- Opcode
			192,168,1,i, -- ip
			6454, -- eth port
			0x0001, -- firmware version
			0, -- net
			i, -- subnet
			0x00ff, -- OEM
			0, -- Ubea version
			0xd2,  -- Status1
			0, -- EstaMan
			str("Test\0", 18), -- short name
			str(string.format("Driver %d",i), 64), -- long name
			str("status\0", 64), -- text status
			1, -- num port
			0xc0c0c0c0, -- port type
			0x08808080, --Good input
			0x80808080, -- Good output
			0x00000000, -- SwIn
			0x00000000, -- SwOut
			0, -- SwVideo
			0, -- SwMacro
			0, -- SwRemote
			0, -- Spare1
			0, -- Spare2
			0, -- Spare3
			0, -- Style
			"\1\2\3\4\5\6", -- mac
			192,168,1,245,
			0, --BindIndex
			8, -- Status
			str("",26)
		)
		self.udp:sendto(to_send, ip, port)
	end
end

function LEDsController:decodeArtnetReply(data)
	local _,
		id,
		opp,
		ip1,ip2,ip3,ip4, -- ip
		port, -- eth port
		firmware, -- firmware version
		net, -- net
		subnet, -- subnet
		OEM, -- OEM
		Ubea, -- Ubea version
		Status1,  -- Status1
		EstaMan, -- EstaMan
		short_name, -- short name
		long_name, -- long name
		status, -- text status
		nb_port, -- num port
		port_type, -- port type
		good_input, --Good input
		good_output, -- Good output
		SwIn, -- SwIn
		SwOut, -- SwOut
		SwVideo, -- SwVideo
		SwMacro, -- SwMacro
		SwRemote, -- SwRemote
		Spare1, -- Spare1
		Spare2, -- Spare2
		Spare3, -- Spare3
		Style, -- Style
		mac1,mac2,mac3,mac4,mac5,mac6, -- mac
		remoteIp1,remoteIp2,remoteIp3,remoteIp4,
		bindIndex, --BindIndex
		Status2 = upack(data, "zHBBBBHHBBHBBHc18c64c64>HIIIIIBBBBBBBBBBBBBBBBBBB")

	-- print(id , ip1,ip2,ip3,ip4)

	_, short_name = upack(short_name,"z")
	_, long_name = upack(long_name,"z")
	_, status = upack(status,"z")

	local t = {
		id          = id,
		opp         = opp,
		ip          = {ip1,ip2,ip3,ip4},
		port        = port,
		firmware    = firmware,
		net         = net,
		subnet      = subnet,
		OEM         = OEM,
		Ubea        = Ubea,
		Status1     = Status1,
		EstaMan     = EstaMan,
		short_name  = short_name,
		long_name   = long_name,
		status      = status,
		nb_port     = nb_port,
		port_type   = port_type,
		good_input  = good_input,
		good_output = good_output,
		SwIn        = SwIn,
		SwOut       = SwOut,
		SwVideo     = SwVideo,
		SwMacro     = SwMacro,
		SwRemote    = SwRemote,
		Spare1      = Spare1,
		Spare2      = Spare2,
		Spare3      = Spare3,
		Style       = Style,
		mac         = {mac1,mac2,mac3,mac4,mac5,mac6},
		remoteIp    = {remoteIp1,remoteIp2,remoteIp3,remoteIp4},
		bindIndex   = bindIndex
	}
	self:printD(string.format([[
	ip:		%d.%d.%d.%d
	port:		%d
	art-vers:	0x%04x
	net:		%d
	subset:		%d
	Oem:		0x%04x
	short_name:	'%s'
	long_name:	'%s'
	report:		'%s'
	]],
		t.ip[1], t.ip[2], t.ip[3], t.ip[4],
		t.port,
		t.firmware,
		t.net,
		t.subnet,
		t.OEM,
		t.short_name,
		t.long_name,
		t.status
	))
	return t
end


function LEDsController:sendArtnetPoll()

		local to_send = pack(
		"AHHbb",
		ART_HEAD,
		ART_POLL, -- Opcode
		ARTNET_VERSION,
		06,
		00
	)
	self.udp:sendto(to_send, "255.255.255.255", self.port)
end

function LEDsController:receiveArtnet(receive_data, remote_ip, remote_port)
	local _,_, opcode = upack(receive_data, "zH")
	-- self:printD("RECEIVE from", remote_ip, remote_port)
	-- self:printD(string.format("0x%04x",opcode))
	if opcode == ART_POLL then
		-- self:printD("Art-Net POLL from:", remote_ip, remote_port)
		-- self:sendArtnetPollReply(remote_ip, remote_port)
		return "poll"
	elseif opcode == ART_REPLY then
		self:printD("Art-Net POLL_REPLY from:", remote_ip, remote_port)
		local d = self:decodeArtnetReply(receive_data)
		return "reply", d
	elseif opcode == ART_DMX then
		self:printD("Art-Net DMX from:", remote_ip, remote_port)
		local uni,net,seq = self:decodeArtnetDMX(receive_data)
			-- if uni == 3 then
			-- 	return "sync"
			-- end
		return "dmx"
	elseif opcode == ART_SYNC then
		self:printD("Art-Net SYNC from:", remote_ip, remote_port)
		return "sync"
	end
end

function LEDsController:setLED(m, r, g, b, w)
	if self.rgbw and self.rgbw_mode ~= 0 then
		if self.rgbw_mode == 1 then
			w = math.min(r,g,b)
		elseif self.rgbw_mode == 2 then
			w = math.min(r,g,b)
			r,g,b = r-w, g-w, b-w
		elseif self.rgbw_mode == 3 then
			w = (math.max(r,g,b) + math.min(r,g,b)) / 2
		end
	else
		w = 0
	end

	r = r * self.bright
	g = g * self.bright
	b = b * self.bright
	w = w * self.bright

	self.leds[m.id+1] = {r,g,b,w}
end

------------------------------- RGB888 ----------------------------------------

function LEDsController:sendLED888(off, len, show)
	-- self:printD("sendLED888", off, len, show)
	local to_send = pack("bbHH", (show and LED_RGB_888_UPDATE or LED_RGB_888), self.count%256, off, len)
	self.count = self.count + 1
	local data = self.leds
	for i=0,len-1 do
		to_send = to_send..pack(
		"bbb",
		data[off+i+1][1],
		data[off+i+1][2],
		data[off+i+1][3]
	)
	end
	self.udp:sendto(to_send, self.ip, self.port)
end

function LEDsController:sendAll888(nb_led, update, delay)
	local max_update = math.floor(MAX_UPDATE_SIZE / 3)
	local nb_update = math.ceil(nb_led / max_update)
	self:printD("#RGB888", nb_led*3, nb_update)
	for i=0, nb_update-2 do
		self:sendLED888(i * max_update, max_update, false)
		socket.sleep(delay/nb_update)
	end
	local last_off = max_update * (nb_update-1)
	self:sendLED888(last_off, nb_led - last_off, update)
	socket.sleep(delay/nb_update)
end

------------------------------- RGB565 ----------------------------------------

local function conv888to565(color)
	local r = color[1]
	local g = color[2]
	local b = color[3]

	r = bit.rshift(r, 3)
	r = bit.lshift(r, 6)

	g = bit.rshift(g, 2)
	r = bit.bor(r,g)
	r = bit.lshift(r, 5)

	b = bit.rshift(b, 3)
	r = bit.bor(r,b)
	-- print(color[1],color[2],color[3],r)
	return r
end

function LEDsController:send565LED(off, len, show)
	-- self:printD(off, len)
	local to_send = pack("bbHH", (show and LED_RGB_565_UPDATE or LED_RGB_565), self.count%256, off, len)
	self.count = self.count + 1
	local data = self.leds
	for i=0,len-1 do
		to_send = to_send..pack("H", conv888to565(data[i+1]))
	end
	self.udp:sendto(to_send, self.ip, self.port)
end

function LEDsController:sendAll565(nb_led, update, delay)
	local max_update = math.floor(MAX_UPDATE_SIZE / 2)
	local nb_update = math.ceil(nb_led / max_update)
	self:printD("#565",nb_led, nb_update)
	for i=0, nb_update-2 do
		self:send565LED(i * max_update, max_update, false)
		socket.sleep(delay/nb_update)
	end
	local last_off = max_update * (nb_update-1)
	self:send565LED(last_off, nb_led - last_off, update)
	socket.sleep(delay/nb_update)
end

---------------------------------- RLE888 -------------------------------------

local function cpm_color(c1, c2)
	return (c1[1] == c2[1] and c1[2] == c2[2] and c1[3] == c2[3])
end

function LEDsController:compressRLE888(led_nb)
	local color = self.leds[1]
	local nb = 0
	local data = {}
	local size = 0
	local pqt = 1

	for i=1,led_nb+1 do
		if i == led_nb+1 then
			-- print("lst",i)
			if not data[pqt] then
				data[pqt] = {}
				data[pqt].str = ""
				data[pqt].led_nb = nb
				if (data[pqt-1]) then
					data[pqt].off = data[pqt-1].off + data[pqt-1].led_nb
				else
					data[pqt].off = 0
				end
			end
			data[pqt].str = data[pqt].str..pack("bbbb",
				(nb),
				color[1],
				color[2],
				color[3]
			)
			size = size + 4
			data[pqt].led_nb = data[pqt].led_nb + nb
		elseif cpm_color(color, self.leds[i]) and nb < 255 then
			nb = nb + 1
		else
			if not data[pqt] then
				data[pqt] = {}
				data[pqt].str = ""
				data[pqt].led_nb = 0
				if (data[pqt-1]) then
					data[pqt].off = data[pqt-1].off + data[pqt-1].led_nb
				else
					data[pqt].off = 0
				end
			end
			data[pqt].str = data[pqt].str..pack(
				"bbbb",
				nb,
				color[1],
				color[2],
				color[3]
			)
			data[pqt].led_nb = data[pqt].led_nb + nb
			color = self.leds[i]

			nb = 1
			size = size + 4
			if size % MAX_UPDATE_SIZE == 0 then
				pqt = pqt+1
			end
		end
	end
	return data, size
end

function LEDsController:sendRLE888(data, show, delay)
	self:printD("#RLE888", #data)
	-- for k,v in pairs(data) do
	-- 	print("=",k,v.led_nb,v.off)
	-- end
	local nb = #data
	for i=1,nb-1 do
		local to_send = pack(
			"bbHH",
			LED_RLE_888,
			self.count%256,
			data[i].off,
			data[i].led_nb)..data[i].str
		self.count = self.count + 1
		self.udp:sendto(to_send, self.ip, self.port)
	end
	local to_send = pack(
		"bbHH",
		(show and LED_RLE_888_UPDATE or LED_RLE_888),
		self.count%256,
		data[nb].off,
		data[nb].led_nb)..data[nb].str
	self.count = self.count + 1
	self.udp:sendto(to_send, self.ip, self.port)
	socket.sleep(delay)
end

function LEDsController:sendAllRLE888(led_nb, leds_show, delay_pqt)

	local data, size = self:compressRLE888(led_nb)

	if #data < math.ceil(led_nb / (MAX_UPDATE_SIZE/3)) then
		self:sendRLE888(data, leds_show, delay_pqt)
	else
		self:sendAll888(led_nb, leds_show, delay_pqt)
	end

	-- self:printD(string.format([[
	-- ART-NET:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	-- RGB-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	-- RLE-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S;	%0.03f%% (RLE-888 VS RGB-888)
	-- ]],
	--
	-- 	math.ceil(led_nb / LEDS_BY_UNI)+1,
	-- 	led_nb*3/1024,
	-- 	(math.ceil(led_nb / LEDS_BY_UNI)+1)*60,
	--
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/3)),
	-- 	(led_nb*3)/1024,
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/3))*60,
	--
	-- 	#data,
	-- 	size/1024,
	-- 	#data * 60,
	-- 	size/(led_nb*3)*100
	-- ))
end


---------------------------------- BRO888 --------------------------------------


function LEDsController:compressBRO888()
	-- self:printD("compressBRO888")
	local data = self.leds
	local to_compress = ""
	for i=0,self.led_nb-1 do
		to_compress = to_compress..pack(
		"bbb",
		data[i+1][1],
		data[i+1][2],
		data[i+1][3]
	)
	end
	local options = {
		mode = brotli.MODE_GENERIC,
		quality = 1,
		lgwin = 10,
		lgblock = 16,
	}
	local cmp = brotli.compress(to_compress,options)
	return cmp, #cmp
end

function LEDsController:sendBRO888(data, leds_show, delay_pqt)
	self:printD("#BRO888", #data)
	local to_send = pack("bbHH", (leds_show and LED_BRO_888_UPDATE or LED_BRO_888), self.count%256, 0, self.led_nb)..data
	self.count = self.count + 1
	self.udp:sendto(to_send, self.ip, self.port)
	socket.sleep(delay_pqt)
end

function LEDsController:sendAllBRO888(led_nb, leds_show, delay_pqt)

	local bro_data, bro_size = self:compressBRO888()
	-- local z_data, z_size = self:compressZ888()
	if bro_size > 1400 then
		self:sendAll888(led_nb, leds_show, delay_pqt)
	else
		self:sendBRO888(bro_data, leds_show, delay_pqt)
	end


	-- self:printD(string.format([[
	-- ART-NET:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	-- RGB-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	-- RGB-565:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	-- RLE-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S;	%0.03f%% (RLE-888 VS RGB-888)
	-- BRO-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S;	%0.03f%% (BRO-888 VS RGB-888)
	-- Z-888:    %02d pqt/frame;	%0.3f Ko;	%02d pqt/S;	%0.03f%% (Z-888 VS RGB-888)
	-- ]],
	--
	-- 	math.ceil(led_nb / LEDS_BY_UNI)+1,
	-- 	led_nb*3/1024,
	-- 	(math.ceil(led_nb / LEDS_BY_UNI)+1)*60,
	--
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/3)),
	-- 	(led_nb*3)/1024,
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/3))*60,
	--
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/2)),
	-- 	(led_nb*2)/1024,
	-- 	math.ceil(led_nb / (MAX_UPDATE_SIZE/2))*60,
	--
	-- 	math.ceil(rle_size / MAX_UPDATE_SIZE),
	-- 	rle_size/1024,
	-- 	math.ceil(rle_size / MAX_UPDATE_SIZE)*60,
	-- 	rle_size/(led_nb*3)*100,
	--
	-- 	math.ceil(bro_size / MAX_UPDATE_SIZE),
	-- 	bro_size/1024,
	-- 	math.ceil(bro_size / MAX_UPDATE_SIZE)*60,
	-- 	bro_size/(led_nb*3)*100,
	--
	-- 	math.ceil(z_size / MAX_UPDATE_SIZE),
	-- 	z_size/1024,
	-- 	math.ceil(z_size / MAX_UPDATE_SIZE)*60,
	-- 	z_size/(led_nb*3)*100
	-- ))
end

---------------------------------- Z888 ----------------------------------------


function LEDsController:compressZ888(nb, off)
	local nb = nb or self.led_nb
	local off = off or 0
	-- self:printD("compressZ888")
	local data = self.leds
	local to_compress = ""
	for i=off,off+nb-1 do
		to_compress = to_compress..pack(
		"bbb",
		data[i+1][1],
		data[i+1][2],
		data[i+1][3]
	)
	end
	local cmp = love.data.compress("string", "zlib", to_compress)
	return cmp, #cmp
end

function LEDsController:compressZ565(nb, off)
	local nb = nb or self.led_nb
	local off = off or 0
	-- self:printD("compressZ888")
	local data = self.leds
	local to_compress = ""

	for i=off,off+nb-1 do
		to_compress = to_compress..pack("H", conv888to565(data[i+1]))
	end

	local cmp = love.data.compress("string", "zlib", to_compress)
	return cmp, #cmp
end


function LEDsController:sendZ888(data, leds_show, delay_pqt)
	self:printD("#Z888", #data, leds_show)
	local to_send = pack("bbHH", (leds_show and LED_Z_888_UPDATE or LED_Z_888), self.count%256, 0, self.led_nb, off)..data
	self.count = self.count + 1
	self.udp:sendto(to_send, self.ip, self.port)
	socket.sleep(delay_pqt)
end

function LEDsController:sendAllZ888(led_nb, leds_show, delay_pqt)

	local z_data, z_size = self:compressZ888()
	if z_size > 1400 then
		self:sendAll888(led_nb, leds_show, delay_pqt)
	else
		self:sendZ888(z_data, leds_show, delay_pqt)
	end


	self:printD(string.format([[
	ART-NET:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	RGB-888:  %02d pqt/frame;	%0.3f Ko;	%02d pqt/S
	Z-888:    %02d pqt/frame;	%0.3f Ko;	%02d pqt/S;	%0.03f%% (Z-888 VS RGB-888)
	]],

		math.ceil(led_nb / LEDS_BY_UNI)+1,
		led_nb*3/1024,
		(math.ceil(led_nb / LEDS_BY_UNI)+1)*60,

		math.ceil(led_nb / (MAX_UPDATE_SIZE/3)),
		(led_nb*3)/1024,
		math.ceil(led_nb / (MAX_UPDATE_SIZE/3))*60,

		math.ceil(z_size / MAX_UPDATE_SIZE),
		z_size/1024,
		math.ceil(z_size / MAX_UPDATE_SIZE)*60,
		z_size/(led_nb*3)*100
	))
end

function LEDsController:sendUDPX(led_nb)
	self:printD("#UDPX")
	local to_send = pack("bbHH", 0x50, self.count%256, 1, self.led_nb)
	self.count = self.count + 1
	local data = self.leds
	-- local crc = 0
	for i=0,led_nb-1 do
		to_send = to_send..pack(
			"bbb",
			data[i+1][1],
			data[i+1][2],
			data[i+1][3]
		)
	end
	-- for i=0,led_nb-1 do
	-- 	crc = bxor(crc, to_send:byte(1+5+i))
	-- end
	-- to_send = to_send..pack("b", crc)
	self.udp:sendto(to_send, self.ip, self.port)
end

function LEDsController:sendAllUDPX(led_nb, leds_show, delay_pqt)
	self:sendUDPX(led_nb)
	socket.sleep(delay_pqt)
end

function LEDsController:sendUDPX565(led_nb)
	self:printD("#UDPX565")
	local to_send = pack("bbHH", 0x52, self.count%256, 0, self.led_nb)
	self.count = self.count + 1
	local data = self.leds

	local z_data, z_size = self:compressZ565()
	to_send = to_send..z_data

	self.udp:sendto(to_send, self.ip, self.port)
end

function LEDsController:sendAllUDPX565(led_nb, leds_show, delay_pqt)
	self:sendUDPX565(led_nb)
	socket.sleep(delay_pqt)
end

--------------------------------------------------------------------------------

function LEDsController:start_dump(pro, name)
	local protocol = 42
	if pro == "RGB888" then
		self.dump = self.dump_888
		protocol = LED_RGB_888
	elseif pro == "RGB565" then
		self.dump = self.dump_565
		protocol = LED_RGB_565
	elseif pro == "RLE888" then
		self.dump = self.dump_RLE
		protocol = LED_RLE_888
	elseif pro == "BRO888" then
		if brotli then
			self.dump = self.dump_BRO
			protocol = LED_BRO_888
		else
			self.dump = self.dump_888
			protocol = LED_RGB_888
		end
	else
		error("dump pro unknow", pro)
		return
	end
	self.dump_file = io.open("dump/"..(name or "anim").."."..pro, "w")
	if not self.dump_file then
		error("Can't write: 'dump/"..(name or "anim").."."..pro.."'")
	end
	self.dump_file:write(pack("bHH", protocol, 30, self.led_nb))
end

function LEDsController:dump_888()
	local to_dump = ""
	local data = self.leds
	for i=0,self.led_nb-1 do
		to_dump = to_dump..pack("bbb", data[i+1][1], data[i+1][2], data[i+1][3])
	end
	self.dump_file:write(to_dump)
end

function LEDsController:dump_565()
	local to_dump = ""
	local data = self.leds
	for i=0,self.led_nb-1 do
		to_dump = to_dump..pack("H", conv888to565(data[i+1]))
	end
	self.dump_file:write(to_dump)
end

function LEDsController:dump_RLE()
	local to_dump = ""
	local data, size = self:compressRLE888(self.led_nb)
	local nb = #data
	for k,v in ipairs(data) do
		to_dump = to_dump .. v.str
	end
	self.dump_file:write(to_dump)
end

function LEDsController:dump_BRO()
	local bro_data, bro_size = self:compressBRO888()
	self.dump_file:write(pack("H", bro_size) .. bro_data )
end

function LEDsController:dump_Z()
	local z_data, z_size = self:compressZ888()
	self.dump_file:write(pack("H", z_size) .. z_data )
end

--------------------------------------------------------------------------------

function LEDsController:send(delay_pqt, sync, ctn)
	self:protocol(self.led_nb, sync, delay_pqt or 0, ctn)
end

--------------------------------------------------------------------------------

function color_wheel(WheelPos)
	WheelPos = WheelPos % 255
	WheelPos = 255 - WheelPos
	if (WheelPos < 85) then
		return {255 - WheelPos * 3, 0, WheelPos * 3}
	elseif (WheelPos < 170) then
		WheelPos = WheelPos - 85
		return {0, WheelPos * 3, 255 - WheelPos * 3}
	else
		WheelPos = WheelPos - 170
		return {WheelPos * 3, 255 - WheelPos * 3, 0}
	end
end

--------------------------------------------------------------------------------

LEDsController.upack = upack
LEDsController.pack = pack

return LEDsController
