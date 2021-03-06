#include "AM.h"
#include "SenseMote.h"
#include "Timer.h"

module SenseC @safe() {
  uses {
    interface Boot;
    interface SplitControl as RadioControl;

    interface AMSend as RadioSend[am_id_t id];
    interface Receive as RadioReceive[am_id_t id];
    interface Receive as RadioSnoop[am_id_t id];
    interface Packet as RadioPacket;
    interface AMPacket as RadioAMPacket;

    interface Leds;
    interface Timer<TMilli> as Timer0;
    interface Read<uint16_t> as ReadLight;
    interface Read<uint16_t> as ReadTemperature;
    interface Read<uint16_t> as ReadHumidity;
  }
}

implementation
{
  enum {
    RADIO_QUEUE_LEN = 128,
    CONSECUTIVE_N_MAX = 10,
  };

  message_t  radioQueueBufs[RADIO_QUEUE_LEN];
  message_t  * ONE_NOK radioQueue[RADIO_QUEUE_LEN];
  uint8_t    radioIn, radioOut;
  bool       radioBusy, radioFull;

  RADIO_MSG  node;
  message_t node_msg;
  bool node_ack;

  uint16_t lossCntLast;
  uint16_t consN;
  uint16_t consTotal[CONSECUTIVE_N_MAX * 2 + 1];
  uint16_t consSucc[CONSECUTIVE_N_MAX * 2 + 1];
  uint16_t revCounter;
  task void radioSendTask();

  void dropBlink() {
    call Leds.led2Toggle();
    if (node.nodeid == NODE1)
      node.node1_overflow++;
  }

  void failBlink() {
    call Leds.led2Toggle();
  }

  event void Boot.booted() {
    uint8_t i;

    for (i = 0; i < RADIO_QUEUE_LEN; i++)
      radioQueue[i] = &radioQueueBufs[i];
    radioIn = radioOut = 0;
    radioBusy = FALSE;
    radioFull = TRUE;
    lossCntLast = 0;
    consN = 0;
    revCounter = 0;
    for( i = 0; i <= CONSECUTIVE_N_MAX * 2; i++) {
        consTotal[i] = 0;
        consSucc[i] = 0;
    }

    node.nodeid = TOS_NODE_ID;
    node.counter = -1;
    node_ack = TRUE;
    node.time_period = 100;
    node.total_time = 0;
    node.node2_retrans = 0;
    node.node1_overflow = 0;
    
    if (node.nodeid == NODE2)
      call Timer0.startPeriodic(node.time_period);

    call RadioControl.start();
  }

  event void Timer0.fired()
  {
    message_t *ret;
    RADIO_MSG *btrpkt;

    atomic {
      if (node_ack)
      {
        call ReadLight.read();
        call ReadTemperature.read();
        call ReadHumidity.read();
        node.counter++;
        node_ack = FALSE;
      }
      else
        node.node2_retrans++;
      node.total_time += node.time_period;
      btrpkt = (RADIO_MSG*)(call RadioPacket.getPayload(&node_msg, sizeof(RADIO_MSG)));
      btrpkt->nodeid = node.nodeid;
      btrpkt->counter = node.counter;
      btrpkt->temperature = node.temperature;
      btrpkt->humidity = node.humidity;
      btrpkt->light = node.light;
      btrpkt->time_period = node.time_period;
      btrpkt->total_time = node.total_time;
      btrpkt->node2_retrans = node.node2_retrans;
      node.factor++;
      btrpkt->factor = node.factor;
      call RadioPacket.setPayloadLength(&node_msg, sizeof(RADIO_MSG));
      call RadioAMPacket.setType(&node_msg, AM_RADIO_MSG);
      call RadioAMPacket.setSource(&node_msg, node.nodeid);
      call RadioAMPacket.setDestination(&node_msg, NODE1);
      if (!radioFull)
      {
        ret = radioQueue[radioIn];
        *radioQueue[radioIn] = node_msg;

        radioIn = (radioIn + 1) % RADIO_QUEUE_LEN;

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
        node.node2_retrans--;
        dropBlink();
      }
    }
  }

  event void RadioControl.startDone(error_t error) {
    if (error == SUCCESS) {
      radioFull = FALSE;
    }
  }

  event void RadioControl.stopDone(error_t error) {}

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

  void calTempVar(uint16_t sendCnt, uint16_t revCnt) {

    uint8_t i = 0;

    uint16_t del = sendCnt - revCnt - lossCntLast;
    if(del == 0) {
        if(consN <= CONSECUTIVE_N_MAX && consN != 0) {
            consTotal[consN + CONSECUTIVE_N_MAX]++;
	    consSucc[consN + CONSECUTIVE_N_MAX]++;
        }
        consN ++;  
    } 
    else {
        if(consN <= CONSECUTIVE_N_MAX && consN != 0) consTotal[consN + CONSECUTIVE_N_MAX] ++;
        if(del > CONSECUTIVE_N_MAX) del = CONSECUTIVE_N_MAX;
	else  consSucc[CONSECUTIVE_N_MAX - del] ++;
        for(i = 1; i <= del; i++) {
            consN = i;
            consTotal[CONSECUTIVE_N_MAX - consN] ++;
        }
        consN = 1; 
    }
    
    lossCntLast = sendCnt - revCnt;
		
    return ;
  }

  int16_t calBetaFactor(uint16_t sendCnt, uint16_t revCnt) {
    uint8_t i;
    int16_t esum = 0;
    int16_t bsum = 0; 
    int16_t beta = 0;
    int16_t rate = 0;
    if(sendCnt == 0 || revCnt == sendCnt) return 0;
    rate = revCnt * 100 / sendCnt; 
    for(i = 0; i < CONSECUTIVE_N_MAX; i++) {
        if(consTotal[i] != 0) {
            esum = esum + consSucc[i] * 100 / consTotal[i];
            bsum = bsum + rate;
        }
    }
    for(i = CONSECUTIVE_N_MAX + 1; i <= CONSECUTIVE_N_MAX * 2; i++) {
        if(consTotal[i] != 0) {
            esum = esum + 100 - 100 * consSucc[i] / consTotal[i] ;
            bsum = bsum + 100 - rate;
        }
    }
    beta = (bsum - esum) * 100/ bsum;
    return beta;
  }

  message_t* receive(message_t *msg, void *payload, uint8_t len) {
    message_t *ret = msg;

    atomic {
      if (len == sizeof(ACK_MSG)) {
        ACK_MSG *btrpkt = (ACK_MSG*)payload;
        if (btrpkt->nodeid == node.nodeid)
        {
          if (btrpkt->counter == node.counter)
            node_ack = TRUE;
        }
        else
          if (node.nodeid == NODE1)
          {
            call RadioPacket.setPayloadLength(msg, sizeof(ACK_MSG));
            call RadioAMPacket.setType(msg, AM_RADIO_MSG);
            call RadioAMPacket.setSource(msg, node.nodeid);
            call RadioAMPacket.setDestination(msg, NODE2);
            if (!radioFull)
    	    {
	      ret = radioQueue[radioIn];
	      *radioQueue[radioIn] = *msg;
	      radioIn = (radioIn + 1) % RADIO_QUEUE_LEN;
	      if (radioIn == radioOut)
	        radioFull = TRUE;
	      if (!radioBusy)
	      {
	        post radioSendTask();
	        radioBusy = TRUE;
	      }
              call Leds.led2Toggle();
	    }
            else
	      dropBlink();
          }
      }
      if ((len == sizeof(RADIO_MSG)) && ((call RadioAMPacket.source(msg)) == NODE2)){
        RADIO_MSG *btrpkt = (RADIO_MSG*)payload;
        btrpkt->node1_overflow = node.node1_overflow;
        revCounter++;
	calTempVar(btrpkt->counter + btrpkt->node2_retrans + 1, revCounter); 
        //if (btrpkt->node2_retrans == 0) btrpkt->factor = 0;
        //else 
        btrpkt->factor = calBetaFactor(btrpkt->counter + btrpkt->node2_retrans + 1, revCounter);
        call RadioPacket.setPayloadLength(msg, sizeof(RADIO_MSG));
        call RadioAMPacket.setType(msg, AM_RADIO_MSG);
        call RadioAMPacket.setSource(msg, node.nodeid);
        call RadioAMPacket.setDestination(msg, NODE0);
        if (!radioFull)
	  {
	    ret = radioQueue[radioIn];
	    *radioQueue[radioIn] = *msg;
	    radioIn = (radioIn + 1) % RADIO_QUEUE_LEN;
	    if (radioIn == radioOut)
	      radioFull = TRUE;
	    if (!radioBusy)
	    {
	      post radioSendTask();
	      radioBusy = TRUE;
	    }
            call Leds.led1Toggle();
	  }
          else
	    dropBlink();
      }
      if (len == sizeof(TIME_MSG)) {
        TIME_MSG *btrpkt = (TIME_MSG *)payload;
        node.time_period = btrpkt->time_period;
        if (node.nodeid == NODE1)
          {
            call RadioPacket.setPayloadLength(msg, sizeof(TIME_MSG));
            call RadioAMPacket.setType(msg, AM_RADIO_MSG);
            call RadioAMPacket.setSource(msg, node.nodeid);
            call RadioAMPacket.setDestination(msg, NODE2);
            if (!radioFull)
    	    {
	      ret = radioQueue[radioIn];
	      *radioQueue[radioIn] = *msg;
	      radioIn = (radioIn + 1) % RADIO_QUEUE_LEN;
	      if (radioIn == radioOut)
	        radioFull = TRUE;
	      if (!radioBusy)
	      {
	        post radioSendTask();
	        radioBusy = TRUE;
	      }
              call Leds.led2Toggle();
	    }
            else
	      dropBlink();
          }
        else
        {
          call Timer0.stop();
          call Timer0.startPeriodic(node.time_period);
        }
      }
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
      len = call RadioPacket.payloadLength(msg);
      addr = call RadioAMPacket.destination(msg);
      source = call RadioAMPacket.source(msg);
      id = call RadioAMPacket.type(msg);

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

  event void ReadTemperature.readDone(error_t result, uint16_t data)
  {
    if (result == SUCCESS)
      node.temperature = data;
  }

  event void ReadHumidity.readDone(error_t result, uint16_t data)
  {
    if (result == SUCCESS)
      node.humidity = data;
  }

  event void ReadLight.readDone(error_t result, uint16_t data)
  {
    if (result == SUCCESS)
      node.light = data;
  }
}

