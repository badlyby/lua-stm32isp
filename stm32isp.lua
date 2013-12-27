--Windows
--lua stm32isp.lua COM1 read backup.bin
--lua stm32isp.lua COM1 erase
--lua stm32isp.lua COM1 write file.bin
--lua stm32isp.lua COM1 protect

--Linux-Ubuntu
--sudo lua stm32isp.lua /dev/ttyUSB0 read backup.bin
--sudo lua stm32isp.lua /dev/ttyUSB0 erase
--sudo lua stm32isp.lua /dev/ttyUSB0 write file.bin
--sudo lua stm32isp.lua /dev/ttyUSB0 protect


usart = require("usart")
bit = require("bit")
port = nil

function byte2hex(dat)
  local str = ""
  for i=1,#dat do
    str = str .. string.format('%02X ',dat:byte(i))
  end
  return str
end

function setPWR(pwr)
  if pwr then
    port:setDTR(0)
  else
    port:setDTR(1)
  end
end

function setISP(isp)
  if isp then
    port:setRTS(0)
  else
    port:setRTS(1)
  end
end

function open(portname)
  port = usart.open(portname,115200,8,1,"e")
end

function wait_read(len)
  local tmp,ret
  local count=0
  local dat=""
  for i=1,100 do
    if i == 100 then
      print("timeout")
      return dat,count
    end
    tmp,ret = port:read(len)
    if ret > 0 then
      if dat == nil then
        dat = tmp
      else
        dat = dat..tmp
      end
      len = len - ret
      count = count + ret;
    end
    if len == 0 then
      break
    end
    usart.msleep(1)
  end
  return dat,count
end

function hex2char(h)
  return string.format('%02X ', h:byte(1))
end

function cmdtext(cmd)
  if cmd == nil then
    return nil
  end
  return string.format('%02X ', cmd)
end

function _wait_for_ask(info)
  local ask,len = wait_read(1)
  if len ~= 1 then
    print("Can't read port or timeout")
    return false
  else
    if ask:byte(1) == 0x79 then
      return true
    elseif ask:byte(1) == 0x1f then
      return false
    else
      return false
    end
  end
end

function reset()
  setPWR(false)
  usart.msleep(100)
  setPWR(true)
  usart.msleep(500)
end

function initChip()
  setISP(true)
  reset()
  for i=1,200 do
    port:write(string.char(0x7F))
    usart.msleep(50)
    ret,len = port:read(1)
    if len == 1 then
      if ret:byte(1) == 0x79 then
        return true
      elseif ret:byte(1) == 0x1f then
        return true
      end
    end
  end
  return false
end

function releaseChip()
  setISP(false)
  reset()
end

function cmdGeneric(cmd)
  port:write(string.char(cmd, bit.band(bit.bnot(cmd), 0xFF)))
  return _wait_for_ask(cmdtext(cmd))
end

function cmdGet()
  local ver,dat,len
  if cmdGeneric(0x00) then
    len = wait_read(1)
    ver = wait_read(1)
    print("    Bootloader version: "..cmdtext(ver:byte(1)))
    dat = wait_read(len:byte(1))
    print "    Available commands: "
    local str = ""
    for i=1,len:byte(1) do
      str = str .. string.format('%02X ', dat:byte(i))
    end
    print(str)
    _wait_for_ask("0x00 end")
    return ver
  end
  print("Get (0x00) failed")
  return 0
end

function cmdGetVersion()
  local ver,tmp
  if cmdGeneric(0x01) then
    ver = wait_read(1)
    tmp = wait_read(2)
    if not _wait_for_ask("0x01 end") then
      return 0
    end
    print("    Bootloader version: "..cmdtext(ver:byte(1)))
    return ver:byte(1)
  end
  print("GetVersion (0x01) failed")
  return 0
end

function cmdGetID()
  local len,id
  if cmdGeneric(0x02) then
    len = wait_read(1)
    len = len:byte(1)+1
    id = wait_read(len)
    if not _wait_for_ask("0x02 end") then
      return nil,0
    end
    return id,len
  end
  print("GetID (0x02) failed")
  return nil,0
end

function int2byte(num)
  local res={}
  for k=4,1,-1 do
    local mul=2^(8*(k-1))
    res[k]=math.floor(num/mul)
    num=num-res[k]*mul
  end
  local t={}
  for k=1,4 do
    t[k]=res[5-k]
  end
  return string.char(unpack(t))
end

function byte2int(str)
  local t={str:byte(1,-1)}
  local tt={}
  for k=1,#t do
    tt[#t-k+1]=t[k]
  end
  local n=0
  for k=1,#tt do
    n=n+tt[k]*2^((k-1)*8)
  end
  return n
end

function _encode_addr(addr)
  local str = int2byte(addr)
  local crc = bit.bxor(str:byte(1), str:byte(2), str:byte(3), str:byte(4))
  str = str..string.char(bit.band(crc,0xff))
  return str
end

function cmdReadMemory(addr, lng)
  if lng > 256 then
    return nil,0
  end
  if cmdGeneric(0x11) then
    local n = string.char(lng-1,bit.band(bit.bxor((lng - 1), 0xff)))
    port:write(_encode_addr(addr))
    if not _wait_for_ask("0x11 address failed") then
      return nil,0
    end
    port:write(n)
    if not _wait_for_ask("0x11 length failed") then
      return nil,0
    end
    return wait_read(lng)
  end
  print("Read memory (0x11) failed")
  return nil,0
end

function cmdGo(addr)
  if cmdGeneric(0x21) then
    print("*** Go command")
    local p = _encode_addr(addr)
    port:write(p)
    return(_wait_for_ask("0x21 go failed"))
  else
    print("Go (0x21) failed")
    return false
  end
end

function cmdWriteMemory(addr,data,len)
  if len > 256 then
    return false
  end
  local dlen = #data
  if cmdGeneric(0x31) then
    port:write(_encode_addr(addr))
    if not _wait_for_ask("0x31 address failed") then
      return false
    end
    port:write(string.char(len-1))
    local crc = (len-1)
    local c
    for i = 1, len do
      if i <= dlen then
        c = data:byte(i)
      else
        c = 0xff;
      end
      crc = bit.bxor(crc, c)
      port:write(string.char(c))
    end
    port:write(string.char(crc))
    if not _wait_for_ask("0x31 programming failed") then
      return false
    end
    return true
  end
  print("Write memory (0x31) failed")
  return false
end

function cmdEraseMemory(f,t)
  if cmdGeneric(0x43) then
    if (t-f) == 0 then
      port:write(string.char(0xff,0x00))
    else
      local c = (t - f) - 1
      port:write(string.char(c))
      local crc = 0xff
      for c = f, t do
        crc = bit.bxor(crc, c)
	port:write(string.char(c))
      end
      port:write(string.char(crc))
    end
    if not _wait_for_ask("0x43 erasing failed") then
      return false
    end
    print("    Erase memory done")
    return true
  end
  print("Erase memory (0x43) failed")
  return false
end

function cmdWriteProtect(f,t)
  if cmdGeneric(0x63) then
    local c = (t - f) - 1
    port:write(string.char(c))
    local crc = 0xff
    for c = f, t do
      crc = bit.bxor(crc, c)
      port:write(string.char(c))
    end
    port:write(string.char(crc))
    if not _wait_for_ask("0x63 write protect failed") then
      return false
    end
    print("    Write protect done")
    return true
  end
  return false
end

function cmdWriteUnprotect()
  if cmdGeneric(0x73) then
    if not _wait_for_ask("0x73 write unprotect 2 failed") then
      return false
    end
    print("    Write Unprotect done")
    return true
  end
  print("Write Unprotect (0x73) failed")
  return false
end

function cmdReadoutProtect()
  if cmdGeneric(0x82) then
    if not _wait_for_ask("0x82 readout protect 2 failed") then
      return false
    end
    print("    Read protect done")
    return true
  end
  print("Readout protect (0x82) failed")
  return false
end

function cmdReadoutUnprotect()
  if cmdGeneric(0x92) then
    if not _wait_for_ask("0x92 readout unprotect 2 failed") then
      return false
    end
    print("    Read Unprotect done")
    return true
  end
  print("Readout unprotect (0x92) failed")
  return false
end

function readMemory(addr, lng)
  local toread = 0
  local timeout = 0
  local data
  while lng>256 do
    local dat,ret = cmdReadMemory(addr + toread, 256)
    if ret > 0 then
      toread = toread + 256
      lng = lng - 256
      if data == nil then
        data = dat
      else
        data = data..dat
      end
    else
      timeout = timeout + 1
      if timeout > 10 then
        return data,toread
      end
    end
  end
  if lng > 0 then
    local dat,ret = cmdReadMemory(addr + toread, lng)
    if ret > 0 then
      toread = toread + 256
      lng = lng - ret
      if data == nil then
        data = dat
      else
        data = data..dat
      end
    end
  end
  return data,toread
end

function writeMemory(addr, data, lng)
  local offset = 0
  while lng > 256 do
    if not cmdWriteMemory(addr, string.sub(data, offset + 1, offset + 256), 256) then
      print("Write block error!")
      return false
    end
    offset = offset + 256
    addr = addr + 256
    lng = lng - 256
  end
  if not cmdWriteMemory(addr, string.sub(data, offset + 1, -1), 256) then
    print("Write block error!")
    return false
  end
  offset = offset + 256
  print("Write done!")
  return true
end

function cmdStart()
  local data,len
  if initChip() then
    cmdGet()
    --cmdGetVersion()
    data,len = cmdGetID()
    if len > 0 then
      print("Chip ID: "..byte2hex(data))
    end
    data,len = cmdReadMemory(0x1ffff7e0,2)
    if len ~= 2 then
      print("Read out Protect")
      return false
    end
      local size = data:byte(2)*256+data:byte(1)
      return true,size
  end
  return false
end

function cmdEraseAll()
  if cmdStart() then
    local opt = string.char(0xA5, 0x5A, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00)
    cmdEraseMemory(0,0)
    return cmdWriteMemory(0x1FFFF800,opt,16)
  else
    return cmdReadoutUnprotect()
  end
end

function getDeviceID()
  return cmdReadMemory(0x1ffff7e8,12)
end
--------------------------------------------------------------------------------
local address = 0x8000000
local chipsize = nil

function ispinit()
  local inited,size = cmdStart()
  if inited then
    print("Flash size: "..string.format('%dKB',size))
    local devid,len = getDeviceID()
    if len > 0 then
      print("Deveice ID: "..byte2hex(devid))
    end
    chipsize = size*1024
  end
  return inited
end

function read2file(filename)
  if not ispinit() then
    return false
  end
  local f = io.open(filename, "w+b")
  if f == nil then
    print("Cannot open file.")
    return false
  end
  print("Reading...")
  local data,len = readMemory(address,chipsize)
  f:write(data)
  f:close()
  return true
end

function writefromfile(filename)
  if not ispinit() then
    return false
  end
  local f = io.open(filename, "rb")
  if f == nil then
    print("Cannot open file.")
    return false
  end
  local current = f:seek()
  local filesize = f:seek("end")
  f:seek("set",current)
  if chipsize ~= nil then
    if filesize > (chipsize) then
      filesize = chipsize
      print("Write files size over chip capacity, the excess discarded!")
    end
  end
  local data = f:read(filesize)
  local len = #data
  f:close()
  print("Writting...")
  return writeMemory(address,data,len)
end

if arg[1] == nil then
  os.exit()
end
open(arg[1])
if port == nil then
  os.exit()
end

if arg[2] ~= nil then
  if arg[2] == "erase" then
    cmdEraseAll()
  end
  if arg[2] == "protect" then
    if initChip() then
      cmdGet()
      cmdReadoutProtect()
    end
  end
  if arg[2] == "read" then
    if arg[3] ~= nil then
      read2file(arg[3])
    else
      print("Please input filename.")
    end
  end
  if arg[2] == "write" then
    if arg[3] ~= nil then
      writefromfile(arg[3])
    else
      print("Please input filename.")
    end
  end
end

if port ~= nil then
  port:close()
end
