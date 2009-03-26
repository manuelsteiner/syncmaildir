#!/usr/bin/env lua5.1

local MDDIFF = 'mddiff'

function log(msg)
--	io.stderr:write(msg,'\n')
end

function trace()
	local t = {}
	local n = 2
	while true do
		local d = debug.getinfo(n,"nl")
		if not d or not d.name then break end
		t[#t+1] = d.name ..":".. (d.currentline or "?")
		n=n+1
	end
	io.stderr:write('TRACE: ',table.concat(t," | "),'\n')
end

function receive(inf,outfile)
	local outf = assert(io.open(outfile,"w"))

	local line = inf:read("*l")
	local len = tonumber(line:match('^chunk (%d+)'))
	while len > 0 do
		local next_chunk = 4096
		if len < next_chunk then next_chunk = len end
		local data = inf:read(next_chunk)
		len = len - data:len()
		outf:write(data)
	end
	outf:close()
end

function receive_delta(inf)
	local cmds = {}
	local line = ""

	repeat
		log('receiving '..#cmds)
		line = inf:read("*l")
		--log('received '..line)
		if line ~= "END" then cmds[#cmds+1] = line end
	until line == "END"

	return cmds
end

function tmp_for(path)
	local newpath = path .. '.new'
	assert(os.execute('test -f '..newpath) ~= 0)
	return newpath
end

function get_full_email(name,hsha,bsha)
	local tmpfile = tmp_for(name)
	io.stdout:write('GET '..name..'\n')
	io.stdout:flush()
	receive(io.stdin, tmpfile)
	local inf = io.popen(MDDIFF .. ' ' .. tmpfile)
	local hsha_l, bsha_l = inf:read('*a'):match('(%S+) (%S+)')
	inf:close()
	if hsha_l == hsha and bsha_l == bsha then
		os.rename(tmpfile, name)
		log('added '..name)
		trace()
		return true
	else
		log('got a different email for '..name)
		os.remove(tmpfile)
		trace()
		return false
	end
end

function sha_file(name)
	local inf = io.popen(MDDIFF .. ' ' .. name)
	local hsha, bsha = inf:read('*a'):match('(%S+) (%S+)') 
	inf:close()
	return hsha, bsha
end

function exists(name)
	local exists = os.execute('test -f '..name)
	if exists == 0 then
		local h, b = sha_file(name)
		return true, h, b
	else
		return false
	end
end

function execute_add(cmd)
	local name, hsha, bsha = cmd:match('^ADD (%S+) (%S+) (%S+)$')
	local ex, hsha_l, bsha_l = exists(name)
	if ex then
		if hash == hsha_l and bsha == bsha_l then
			log('skipping '..name..' already there')
			trace()
			return true
		else
			log('error '..name..' already there but different')
			trace()
			return false
		end
	end
	-- return get_full_email(name,hsha,bsha)
	return (get_full_email(name,hsha,bsha))
end

function execute_delete(cmd)
	local name, hsha, bsha = cmd:match('^DELETE (%S+) (%S+) (%S+)$')
	local ex, hsha_l, bsha_l = exists(name)
	if ex then
		if hsha == hsha_l and bsha == bsha_l then
			log('deleting '..name)
			os.remove(name)
			trace()
			return true
		else
			log('skipping removal '..name..' since differs')
			trace()
			return true
		end
	end
	log('already deleted '..name)
	trace()
	return true
end

function execute_copy(cmd)
	local name_src, hsha, bsha, name_tgt = 
		cmd:match('^COPY (%S+) (%S+) (%S+) TO (%S+)$')
	local ex_src, hsha_src, bsha_src = exists(name_src)
	local ex_tgt, hsha_tgt, bsha_tgt = exists(name_tgt)
	if ex_src and ex_tgt then
		if hsha_src == hsha_tgt and bsha_src == bsha_tgt then
			log('skipping copy of '..name_src..' to '..name_tgt)
			trace()
			return true
		else
			log('unable to copy '..name_src..' to '..name_tgt..' since'..
				' target exists')
			trace()
			return false
		end
	elseif ex_src and not ex_tgt then
		if hsha_src == hsha and bsha_src == bsha then
				log('copy '..name_src..' to '..name_tgt)
				local ok = os.execute('cp '..name_src..' '..name_tgt)
				if ok == 0 then 
					trace()
					return true
				else 
					log('copy '..name_src..' to '..name_tgt..' failed')
					trace()
					return false
				end
		else
				-- sub-optimal, we may reuse body or header 
				return (get_full_email(name_tgt,hsha,bsha))
		end
	elseif not ex_src and ex_tgt then
		if hsha == hsha_tgt and bsha == bsha_tgt then
			log('skipping copy of non existent '..name_src..' to '..
				name_tgt ..' since target already there')
			trace()
			return true
		else
			log('unable to copy non existent '..name_src..' to '..
				name_tgt..' since'.. ' target exists')
			trace()
			return false
		end
	else
		log('add '..name_tgt..' as a copy of the not existing '..name_src)
		return (get_full_email(name_tgt,hsha,bsha))
	end
end

function execute(cmd)
	local opcode = cmd:match('^(%S+)')

	    if opcode == "ADD"           then return execute_add(cmd)
	elseif opcode == "DELETE"        then return execute_delete(cmd)
	elseif opcode == "COPY"          then return execute_copy(cmd)
	elseif opcode == "REPLACEHEADER" then
		local name, hsha, bsha, hsha_new = 
			cmd:match('^REPLACEHEADER (%S+) (%S+) (%S+) WITH (%S+)$')
		local exists = os.execute('test -f '..name)
		if exists then
			local inf = io.popen(MDDIFF .. ' ' .. name)
			local hsha_l, bsha_l = inf:read('*a'):match('(%S+) (%S+)')
			if hsha == hsha_l and bsha == bsha_l then
				local tmpfile = tmp_for(name)
				io.stdout:write('GETHEADER '..name..'\n')
				io.stdout:flush()
				receive(io.stdin, tmpfile)
				-- XXX add the body of local file 'name'
				os.rename(tmpfile, name)
				log('changed header of '..name)
				trace()
				return 
			elseif hsha_l == hsha_new and bsha == bsha_l then
				log('header already changed for '..name)
				trace()
				return
			end
		else
			local tmpfile = tmp_for(name)
			io.stdout:write('GET '..name..'\n')
			io.stdout:flush()
			receive(io.stdin, tmpfile)
			os.rename(tmpfile, name)
			log('added '..name)
			trace()
			return
		end
	elseif opcode == "REPLACE" then
		local name1, hsha1, bsha1, name2, hsha2, bsha2 = 
		   cmd:match('^REPLACE (%S+) (%S+) (%S+) WITH (%S+) (%S+) (%S+)$')
		trace()

	else
		error('Unknown opcode '..opcode)
	end
end

local commands = receive_delta(io.stdin)
log('delta received')
for i,cmd in ipairs(commands) do
	local rc = execute(cmd)
	if not rc then
		log('error executing command '..i..": "..cmd)
		io.stdout:write('ABORT\n')
		io.stdout:flush()
		os.exit(1)
	end
end
log('committing')
io.stdout:write('COMMIT\n')
io.stdout:flush()
os.exit(0)

-- vim:set ts=4:
