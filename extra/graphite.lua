local addr = graphite_addr or '127.0.0.1:2003'

--
--
-- this script will periodically send stats to graphite
-- to enable: put it to cfg.workdir, add reloadfile('graphite.lua')
-- to init.lua and edit graphite_addr abowe
--
--

local ffi = require 'ffi'
local fiber = require 'fiber'
require 'net' -- for ffi.cdef

if not graphite_loaded then
   graphite_loaded = true
   local loop = function ()
      while true do
	 fiber.sleep(60)
	 if type(graphite_sender) == 'function' then
	    graphite_sender()
	 end
      end
   end
   fiber.create(loop)
   ffi.cdef[[
extern int gethostname(char *name, size_t len);
extern char *custom_proc_title;
extern char *primary_addr;

typedef long int time_t;
time_t time(time_t *t);
]]
end

local function gethostname() 
   local buf = ffi.new('char[?]', 64)
   local result = "unknown"
   if ffi.C.gethostname(buf, ffi.sizeof(buf)) ~= -1 then
      result = ffi.string(buf)
   end
   if ffi.C.primary_addr ~= nil then
      result = result .. ":" .. ffi.string(ffi.C.primary_addr)
   end
   if ffi.C.custom_proc_title ~= nil then
      local proctitle = ffi.string(ffi.C.custom_proc_title)
      if #proctitle > 0 then
	 result = result .. proctitle
      end
   end
   return string.gsub(result, '[. ()]+', '_')
end

local function graphite()
   if type(stat) ~= 'table' or type(stat.records) ~= 'table' then
      -- stat module either not loaded or disabled
      return nil
   end
   local hostname = gethostname()
   local time = tostring(tonumber(ffi.C.time(nil)))
   local msg = {}
   for k, v in pairs(stat.records[0]) do
      table.insert(msg, "my.octopus.")
      table.insert(msg, hostname)
      table.insert(msg, ".")
      table.insert(msg, k)
      table.insert(msg, " ")
      table.insert(msg, v)
      table.insert(msg, " ")
      table.insert(msg, time)
      table.insert(msg, "\n")
   end
   return table.concat(msg)
end

local sockaddr = ffi.new('struct sockaddr_in')
local sock = ffi.C.socket(ffi.C.PF_INET, ffi.C.SOCK_DGRAM, 0)

function graphite_sender ()
    local msg = graphite()
    if (graphite_addr ~= addr) then
       ffi.C.atosin(addr, sockaddr)
       addr = graphite_addr
       print('Graphite export to ' .. addr)
    end
    if msg then
       ffi.C.sendto(sock, msg, #msg, 0,
		    ffi.cast('struct sockaddr *', sockaddr), ffi.sizeof(sockaddr))
    end
end

print('Graphite export to ' .. addr)
