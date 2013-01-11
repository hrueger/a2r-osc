osc = require "../"
should = require "should"

length = (b)->
  if b instanceof ArrayBuffer then b.byteLength else b.length

SUPPORTED_GENERATORS = [osc.OscArrayBufferPacketGenerator]

if (nodeBuffer = typeof Buffer is 'function')
  SUPPORTED_GENERATORS.push(osc.OscBufferPacketGenerator)

TEST_MESSAGES = [
  {
    msg: new osc.Message("/osc/documentation", "/node/x/y")
    length: 36
  },
  {
    msg: new osc.Message("/node/x/y", "is", [12, "foo"])
    length: 24
  },
  {
    msg: new osc.Message("/node/x/y", osc.Impulse)
    length: 16
  },
  {
    msg: new osc.Message("/node/color", "r", Number("0xffaabb"))
    length: 20
  }
]

messageEqual = (msg1, msg2)->
  msg1.address.should.be.equal msg2.address
  msg1.typeTag.should.be.equal msg2.typeTag
  msg1.arguments.should.have.length msg2.arguments.length
  for arg, i in msg1.arguments
    if arg
      arg.should.be.equal(msg2.arguments[i])
    else
      should.ok(arg is msg2.arguments[i])
  null

# OSC packet generator mock
class MockOscPacketGenerator extends osc.AbstractOscPacketGenerator
  constructor: (messageOrBundle, dict)->
    super
    @buffer = []

  writeString: (string, encoding="ascii")-> @buffer.push(string)

for name, desc of osc.NUMBERS
  do (name)->
    MockOscPacketGenerator::["write#{name}"] = (value)-> @buffer.push(value)

# OSC packet parser mock
class MockOscPacketParser extends osc.AbstractOscPacketParser
  readString: (encoding, move=true)->
    value = @buffer[@pos]
    @pos++ if move
    value

  isEnd: -> @buffer.length <= @pos

for name, desc of osc.NUMBERS
  do (name)->
    MockOscPacketParser::["read#{name}"] = (move=true)->
      value = @buffer[@pos]
      @pos++ if move
      value

describe "AbstractOscPacketGenerator", ->
  describe "generate a message", ->
    it "should write address, type tag and arguments", ->
      message = new osc.Message("/foo/bar", "i", 12)
      mock = new MockOscPacketGenerator(message)
      array = mock.generate()
      array[0].should.be.equal(message.address)
      array[1].should.be.equal(",i")
      array[2].should.be.equal(12)

    it "should cast values", ->
      message = new osc.Message("/foo/bar", "isfc", [12.3, 5, "15.5", "foo"])
      mock = new MockOscPacketGenerator(message)
      array = mock.generate()
      array[2].should.be.equal(12)
      array[3].should.be.equal("5")
      array[4].should.be.equal(15.5)
      array[5].should.be.equal("f".charCodeAt(0))

  describe "generate a bundle", ->
    it "should write '#bundle', timetag and messages", ->
      bundle = new osc.Bundle(new Date)
        .message("/foo", osc.Impulse)
        .message("/bar", osc.Impulse)

      mock = new MockOscPacketGenerator(bundle)
      array = mock.generate()
      array[0].should.be.equal("#bundle")
      array[1].should.be.equal(0)
      array[2].should.be.equal(1)
      array[3].should.be.equal(12) # size of first message
      array[4].should.be.equal("/foo")
      array[5].should.be.equal(",I")
      array[6].should.be.equal(12) # size of second message
      array[7].should.be.equal("/bar")
      array[8].should.be.equal(",I")

    it "should convert timetag-date to a NTP date", ->
      date = new Date
      date.setTime(date.getTime() + 1000)
      ntp = osc.toNTP(date)
      bundle = new osc.Bundle(date)

      mock = new MockOscPacketGenerator(bundle)
      array = mock.generate()
      for i in [0..1]
        array[i+1].should.be.equal(ntp[i])

describe "AbstractOscPacketParser", ->
  it "should return a Bundle if the first string is '#bundle'", ->
    bundle = new MockOscPacketParser(["#bundle", 0, 1]).parse()
    bundle.should.be.instanceof osc.Bundle

  it "should read bundled messages", ->
    data = ["#bundle", 0, 1]

    msg1 = new osc.Message("/foo", 1)
    msg2 = new osc.Message("/bar", 2)

    messages = [msg1, msg2]

    for msg in messages
      data.push(16) # length
      data.push(msg.address)
      data.push("," + msg.typeTag)
      data.push.apply(data, msg.arguments)

    bundle = new MockOscPacketParser(data).parse()
    
    for elem, i in bundle.elements
      messageEqual(elem, messages[i])

  it "should return a Message if the first string is an address", ->
    message = new MockOscPacketParser(["/foo", ",i", 1]).parse()
    message.should.be.instanceof osc.Message

  describe ".readTimetag", ->
    it "should read a 64bit NTP time from buffer and convert it to a Date object", ->
      # 14236589681638796952 is equal to the 14th Jan 2005 at 17:58:59 and 12 milliseconds UTC
      hi = 3314714339
      lo = 51539608

      mock = new MockOscPacketParser([hi, lo])

      date = mock.readTimetag()
      date.ntpSeconds.should.be.equal hi
      date.ntpFraction.should.be.equal lo
      date.getUTCDate().should.be.equal 14
      date.getUTCMonth().should.be.equal 0
      date.getUTCFullYear().should.be.equal 2005
      date.getUTCHours().should.be.equal 17
      date.getUTCMinutes().should.be.equal 58
      date.getUTCSeconds().should.be.equal 59
      date.getMilliseconds().should.be.equal 12

for generator in SUPPORTED_GENERATORS
  do (generator)->
    describe "#{generator.name}", ->
      it "should generate packets with correct size", ->
        for msg in TEST_MESSAGES
          packet = new generator(msg.msg).generate()
          length(packet).should.be.equal msg.length

      if generator is osc.OscArrayBufferPacketGenerator
        it "should generate packets that are parseable by OscArrayBufferPacketParser", ->
          for msg in TEST_MESSAGES
            packet = new generator(msg.msg).generate()
            message = new osc.OscArrayBufferPacketParser(packet).parse()
            messageEqual(msg.msg, message)
      else
        it "should generate packets that are parseable by OscBufferPacketParser", ->
          for msg in TEST_MESSAGES
            packet = new generator(msg.msg).generate()
            message = new osc.OscBufferPacketParser(packet).parse()
            messageEqual(msg.msg, message)

if nodeBuffer
  describe "OscBufferPacketGenerator", ->
    it "should terminate a string with 0", ->
      string = "/a"
      buffer = new osc.Message(string, osc.Impulse).toBuffer()
      for i in [0..1]
        buffer[i].should.be.equal string.charCodeAt(i)
      for i in [2..3]
        buffer[i].should.be.equal 0

    it "should add additional null characters to string to make the total number of bits a multiple of 32", ->
      string = "/foo"
      buffer = new osc.Message(string, osc.Impulse).toBuffer()
      for i in [0..3]
        buffer[i].should.be.equal string.charCodeAt(i)
      for i in [4..7]
        buffer[i].should.be.equal 0
