#include "AM.h"
#include "Serial.h"
#include "SenseMote.h"

module BaseStationC @safe() {
  uses {
    interface Boot;
    interface SplitControl as SerialControl;
    interface SplitControl as RadioControl;

    interface AMSend as SerialSend[am_id_t id];
    interface Receive as SerialReceive[am_id_t id];
    interface Packet as SerialPacket;
    interface AMPacket as SerialAMPacket;
    
    interface AMSend as RadioSend[am_id_t id];
    interface Receive as RadioReceive[am_id_t id];
    interface Receive as RadioSnoop[am_id_t id];
    interface Packet as RadioPacket;
    interface AMPacket as RadioAMPacket;

    interface Leds;
  }
}

implementation
{
  enum {
    SERIAL_QUEUE_LEN = 64,
    RADIO_QUEUE_LEN = 64,
  };

  message_t  serialQueueBufs[SERIAL_QUEUE_LEN];
  message_t  * ONE_NOK serialQueue[SERIAL_QUEUE_LEN];
  uint8_t    serialIn, serialOut;
  bool       serialBusy, serialFull;

  message_t  radioQueueBufs[RADIO_QUEUE_LEN];
  message_t  * ONE_NOK radioQueue[RADIO_QUEUE_LEN];
  uint8_t    radioIn, radioOut;
  bool       radioBusy, radioFull;

  ACK_MSG    node2;
  bool       node2Lock;
  message_t  node2_msg;

  uint16_t   node0_retrans;

  task void serialSendTask();
  task void radioSendTask();

  void dropBlink() {
    call Leds.led2Toggle();
  }

  void failBlink() {
    call Leds.led2Toggle();
  }

  event void Boot.booted() {
    uint8_t i;

    for (i = 0; i < SERIAL_QUEUE_LEN; i++)
      serialQueue[i] = &serialQueueBufs[i];
    serialIn = serialOut = 0;
    serialBusy = FALSE;
    serialFull = TRUE;

    for (i = 0; i < RADIO_QUEUE_LEN; i++)
      radioQueue[i] = &radioQueueBufs[i];
    radioIn = radioOut = 0;
    radioBusy = FALSE;
    radioFull = TRUE;

    node2.nodeid = NODE2;
    node2.counter = 0;
    node2Lock = FALSE;

    node0_retrans = 0;

    call RadioControl.start();
    call SerialControl.start();
  }

  event void RadioControl.startDone(error_t error) {
    if (error == SUCCESS) {
      radioFull = FALSE;
    }
  }

  event void SerialControl.startDone(error_t error) {
    if (error == SUCCESS) {
      serialFull = FALSE;
    }
  }

  event void SerialControl.stopDone(error_t error) {}
  event void RadioControl.stopDone(error_t error) {}

  uint8_t count = 0;

  message_t* ONE receive(message_t* ONE msg, void* payload, uint8_t len);
  
  event message_t *RadioSnoop.receive[am_id_t id](message_t *msg,
						    void *payload,
						    uint8_t len) {
    return receive(msg, payload, len);
  }
  
  event message_t *RadioReceive.receive[am_id_t id](message_t *msg,
						    void *payload,
						    uint8_t len) {
    return receive(msg, payload, len);
  }

  message_t* receive(message_t *msg, void *payload, uint8_t len) {
    message_t *ret = msg;

    if (len != sizeof(RADIO_MSG))
      return ret;
    if ((call RadioAMPacket.source(msg)) != NODE1)
      return ret;

    atomic {
      RADIO_MSG *btrpkt = (RADIO_MSG*)payload;
      ACK_MSG *ackpkt;
      if (btrpkt->nodeid == node2.nodeid)
        if (btrpkt->counter == node2.counter)
        {
          btrpkt->node0_retrans = node0_retrans;
          call RadioPacket.setPayloadLength(msg, sizeof(RADIO_MSG));
          call RadioAMPacket.setSource(msg, NODE0);
          call RadioAMPacket.setDestination(msg, AM_BROADCAST_ADDR);
          if (!serialFull)
          {
            ret = serialQueue[serialIn];
            *serialQueue[serialIn] = *msg;
            serialIn = (serialIn + 1) % SERIAL_QUEUE_LEN;

            if (serialIn == serialOut)
              serialFull = TRUE;

            if (!serialBusy)
            {
              post serialSendTask();
              serialBusy = TRUE;
            }

            node2.counter++;
          }
          else
          {
	    dropBlink();
            return ret;
          }
        }
        else
          node0_retrans++;

      call SerialPacket.setPayloadLength(&node2_msg, sizeof(ACK_MSG));
      call SerialAMPacket.setSource(&node2_msg, NODE0);
      call SerialAMPacket.setDestination(&node2_msg, NODE1);
      ackpkt = (ACK_MSG*)(call SerialPacket.getPayload(&node2_msg, sizeof(ACK_MSG)));
      ackpkt->nodeid = btrpkt->nodeid;
      ackpkt->counter = btrpkt->counter;

      if (!radioFull)
	{
	  ret = radioQueue[radioIn];
          *radioQueue[radioIn] = node2_msg;
	  if (++radioIn >= RADIO_QUEUE_LEN)
	    radioIn = 0;
	  if (radioIn == radioOut)
	    radioFull = TRUE;

	  if (!radioBusy)
	    {
	      post radioSendTask();
	      radioBusy = TRUE;
	    }
	}
      else
      {
        node0_retrans--;
	dropBlink();
      }
    }
    
    return ret;
  }

  uint8_t tmpLen;
  
  task void serialSendTask() {
    uint8_t len;
    am_id_t id;
    am_addr_t addr, src;
    message_t* msg;
    atomic
    {
      if (serialIn == serialOut && !serialFull)
	{
	  serialBusy = FALSE;
	  return;
	}

      msg = serialQueue[serialOut];
      tmpLen = len = call RadioPacket.payloadLength(msg);
      id = call RadioAMPacket.type(msg);
      addr = call RadioAMPacket.destination(msg);
      src = call RadioAMPacket.source(msg);
      call SerialPacket.clear(msg);
      call SerialAMPacket.setSource(msg, src);

      if (call SerialSend.send[id](addr, serialQueue[serialOut], len) == SUCCESS)
        call Leds.led1Toggle();
      else
      {
	failBlink();
	post serialSendTask();
      }
    }
  }

  event void SerialSend.sendDone[am_id_t id](message_t* msg, error_t error) {
    atomic
    {
      if (error != SUCCESS)
        failBlink();
      else
	if (msg == serialQueue[serialOut])
	  {
	    if (++serialOut >= SERIAL_QUEUE_LEN)
	      serialOut = 0;
	    if (serialFull)
	      serialFull = FALSE;
	  }
      post serialSendTask();
    }
  }

  event message_t *SerialReceive.receive[am_id_t id](message_t *msg,
						   void *payload,
						   uint8_t len) {
    message_t *ret = msg;
    bool reflectToken = FALSE;

    if (len != sizeof(TIME_MSG))
      return ret;

    atomic
    {
      call SerialPacket.setPayloadLength(msg, sizeof(TIME_MSG));
      call SerialAMPacket.setSource(msg, NODE0);
      call SerialAMPacket.setDestination(msg, NODE1);
      if (!radioFull)
	{
	  reflectToken = TRUE;
	  ret = radioQueue[radioIn];
	  *radioQueue[radioIn] = *msg;
	  if (++radioIn >= RADIO_QUEUE_LEN)
	    radioIn = 0;
	  if (radioIn == radioOut)
	    radioFull = TRUE;

	  if (!radioBusy)
	    {
	      post radioSendTask();
	      radioBusy = TRUE;
	    }
	}
      else
	dropBlink();
    }

    if (reflectToken) {
      //call SerialTokenReceive.ReflectToken(Token);
    }
    
    return ret;
  }

  task void radioSendTask() {
    uint8_t len;
    am_id_t id;
    am_addr_t addr,source;
    message_t* msg;
    
    atomic
    {
      if (radioIn == radioOut && !radioFull)
	{
	  radioBusy = FALSE;
	  return;
	}

      msg = radioQueue[radioOut];
      len = call SerialPacket.payloadLength(msg);
      addr = call SerialAMPacket.destination(msg);
      source = call SerialAMPacket.source(msg);
      id = call SerialAMPacket.type(msg);

      call RadioPacket.clear(msg);
      call RadioAMPacket.setSource(msg, source);
    
      if (call RadioSend.send[id](addr, msg, len) == SUCCESS)
        call Leds.led0Toggle();
      else
      {
	failBlink();
	post radioSendTask();
      }
    }
  }

  event void RadioSend.sendDone[am_id_t id](message_t* msg, error_t error) {
    atomic
    {
      if (error != SUCCESS)
        failBlink();
      else
	if (msg == radioQueue[radioOut])
	  {
	    if (++radioOut >= RADIO_QUEUE_LEN)
	      radioOut = 0;
	    if (radioFull)
	      radioFull = FALSE;
	  }
      post radioSendTask();
    }
  }
}

