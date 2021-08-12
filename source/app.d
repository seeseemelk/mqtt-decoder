import std.algorithm;
import std.stdio;
import std.file;
import std.conv;
import std.format;
import std.range;
import std.utf;

ubyte[] convert(string content)
{
	ubyte[] data;
	ubyte v = 0;
	bool firstByte = true;
	foreach (char c; content)
	{
		bool changed = false;
		if (c >= '0' && c <= '9')
		{
			v = cast(ubyte) ((v << 4) | (c - '0'));
			changed = true;
		}
		else if (c >= 'a' && c <= 'f')
		{
			v = cast(ubyte) ((v << 4) | (c - 'a' + 10));
			changed = true;
		}
		else if (c >= 'A' && c <= 'F')
		{
			v = cast(ubyte) ((v << 4) | (c - 'A' + 10));
			changed = true;
		}

		if (changed)
		{
			if (firstByte)
			{
				firstByte = false;
			}
			else
			{
				data ~= v;
				v = 0;
				firstByte = true;
			}
		}
	}

	if (!firstByte)
		data ~= v;

	return data;
}

char toHexChar(int value)
{
	if (value >= 0 && value <= 9)
		return cast(char) ('0' + value);
	else if (value >= 10 && value <= 15)
		return cast(char) ('A' + value - 10);
	else
		assert(0);
}

string toHexString(ubyte[] data)
{
	string str;
	foreach (c; data)
	{
		str ~= toHexChar((c >> 4) & 0x0F);
		str ~= toHexChar(c & 0x0F);
	}
	return str;
}

enum MQTTPacket
{
	reservedLow = 0,
	connect = 1,
	connack = 2,
	publish = 3,
	puback = 4,
	pubrec = 5,
	pubrel = 6,
	pubcomp = 7,
	subscribe = 8,
	suback = 9,
	unsubscribe = 10,
	unsuback = 11,
	pingreq = 12,
	pingresp = 13,
	disconnect = 14,
	reservedHigh = 15
}

auto readVarInt(ubyte[] data)
{
	struct Result
	{
		size_t length;
		ulong num;
		ubyte[] rest;
	}

	Result result;

	int shift = 0;
	do
	{
		result.num |= (data[result.length] & 0x7F) << shift;
		shift += 7;
		result.length++;
	}
	while ((data[result.length - 1] & 0x80) != 0);

	result.rest = data[result.length .. $];
	return result;
}

auto readString(ubyte[] data)
{
	struct Result
	{
		string text;
		ubyte[] rest;
	}

	size_t length = (data[0] << 8) | (data[1]);

	string text = (cast(char[]) data[2 .. length + 2]).toUTF8();
	data = data[length + 2 .. $];

	return Result(text, data);
}

void printPublishPacket(ubyte flags, ubyte[] data)
{
	bool retain = flags & (1 << 0);
	bool dup = (flags & (1 << 3)) != 0;
	int qos = (flags >> 1) & 0b11;

	writefln!" - Flags:";
	writefln!"   - Retain: %s"(retain);
	writefln!"   - Duplicate: %s"(dup);
	writefln!"   - QoS: %d"(qos);
	
	auto topic = readString(data);
	writefln!" - Topic: %s"(topic.text);
	data = topic.rest;

	if (qos == 1 || qos == 2)
	{
		int id = (data[0] << 8) | data[1];
		writefln!" - Packet Identifier: %d"(id);
		data = data[2 .. $];
	}

	string payload = (cast(char[]) data).toUTF8();
	writefln!" - Payload: %s"(payload);
}

void printSubscribePacket(ubyte flags, ubyte[] data)
{
	bool flagsCorrect = (flags & 0xF) == 0b0010;
	int id = (data[0] << 8) | (data[1]);
	writefln!" - Flags valid: %s"(flagsCorrect);
	writefln!" - Packet ID: %d"(id);
	
	data = data[2 .. $];
	while (!data.empty)
	{
		writefln!" - Topic Filter:";

		size_t length = (data[0] << 8) | (data[1]);
		writefln!"   - Size: %d"(length);
		string topic = (cast(char[]) data[2 .. length + 2]).toUTF8();
		writefln!"   - Topic: %s"(topic);
		int qos = data[length + 2] & 0b11;

		writefln!"   - QoS: %d"(qos);

		data = data[length + 3 .. $];
	}
}

void printSubackPacket(ubyte flags, ubyte[] data)
{
	int id = (data[0] << 8) | data[1];
	writefln!" - Packet ID: %d"(id);

	data = data[2 .. $];
	while (!data.empty)
	{
		ubyte v = data[0];
		string result = "invalid";
		if (v == 0x80)
			result = "failed";
		else if (v == 0x00)
			result = "Max QoS 0";
		else if (v == 0x01)
			result = "Max QoS 1";
		else if (v == 0x02)
			result = "Max QoS 2";
		writefln!" - Topic Result: %s"(result);
		data = data[1 .. $];
	}
}

auto readFixedString(ubyte[] data)
{
	struct Result
	{
		string text;
		ubyte[] rest;
	}

	size_t length = (data[0] << 8) | data[1];

	Result result;
	result.text = (cast(char[]) data[2 .. length + 2]).toUTF8();
	result.rest = data[length + 2 .. $];
	return result;
}

void printConnectPacket(ubyte flags, ubyte[] data)
{
	auto protocolName = readFixedString(data);
	data = protocolName.rest;
	writefln!" - Protocol name: %s"(protocolName.text);

	int protocolLevel = data[0];
	string protocolLevelName = "?";
	if (protocolLevel == 4)
		protocolLevelName = "v3.1.1";
	else if (protocolLevel == 5)
		protocolLevelName = "v5.0";
	writefln!" - Protocol version: %d (%s)"(protocolLevel, protocolLevelName);

	int connectFlags = data[1];

	int keepAlive = (data[2] << 8) | data[3];
	writefln!" - Keep Alive: %d"(keepAlive);

	writefln!"   (contents omitted)";
}

void printConnackPacket(ubyte flags, ubyte[] data)
{
	writefln!" - Session present: %b"(data[0] & 1);

	string status;
	switch (data[1])
	{
		case 0:
			status = "accepted";
			break;
		case 1:
			status = "unacceptable protocol version";
			break;
		case 2:
			status = "identifier rejected";
			break;
		case 3:
			status = "server unavailable";
			break;
		case 4:
			status = "bad user name or password";
			break;
		case 5:
			status = "not authorized";
			break;
		default:
			status = "unknown";
			break;
	}

	writefln!" - Status: %s"(status);
}

ubyte[] printMessage(ubyte[] data)
{
	MQTTPacket type = cast(MQTTPacket) (data[0] >> 4);

	auto lengthVarInt = readVarInt(data[1 .. $]);
	auto length = lengthVarInt.num;
	auto rest = lengthVarInt.rest;

	writefln!" - Control Packet type: %s"(type);
	writefln!" - Length: %d"(length);

	if (length > data.length)
	{
		writefln!"   INCOMPLETE PACKET! (missing %d bytes)"(length - data.length);
		length = data.length;
	}

	ubyte flags = data[0];
	ubyte[] packet = rest[0 .. length];

	switch (type)
	{
	case MQTTPacket.connect:
		printConnectPacket(flags, packet);
		break;
	case MQTTPacket.connack:
		printConnackPacket(flags, packet);
		break;
	case MQTTPacket.publish:
		printPublishPacket(flags, packet);
		break;
	case MQTTPacket.subscribe:
		printSubscribePacket(flags, packet);
		break;
	case MQTTPacket.suback:
		printSubackPacket(flags, packet);
		break;
	default:
		writeln("   (contents omitted)");
		break;
	}

	return rest[length .. $];
}

void printMessages(ubyte[] data)
{
	int packet = 0;
	while (!data.empty)
	{
		writefln!"Packet %d:"(packet);
		data = printMessage(data);
		packet++;
	}
}

void main(string[] args)
{
	string content;
	foreach (line; File(args[1]).byLine)
	{
		if (line.canFind("AT+USOWR"))
			content ~= line.split('"')[1];
		else if (line.canFind("+USORD:"))
			content ~= line.split('"')[1];
	}
	//string content = args[1].readText();
	ubyte[] data = convert(content);

	string hex = toHexString(data);
	writeln("Content:");
	writeln(hex);

	writeln("Decoded:");
	printMessages(data);
}
