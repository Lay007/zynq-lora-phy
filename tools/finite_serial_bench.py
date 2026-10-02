"""Finite Heltec trials: retain complete serial lines and count planned IDs."""
from __future__ import annotations
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import math
import time

from lora_per_ideal import ldro_required, test_payload
import per_measure as bench


class LineReader:
    """Serial timeouts may split a line anywhere, including inside its payload."""
    def __init__(self, serial_port):
        self.port, self.buffer = serial_port, b''

    def readline(self, deadline):
        while time.monotonic() < deadline:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                return line.rstrip(b'\r').decode('ascii')
            self.buffer += self.port.read(max(1, self.port.in_waiting))
            if len(self.buffer) > 8192:
                raise ValueError('overlong serial line')
        return None


def fields(line):
    return dict(item.split('=',1) for item in line.split()[1:] if '=' in item)


def parse_rx(line):
    f = fields(line)
    payload = bytes.fromhex(f['payload'])
    if len(payload) != int(f['len']):
        raise ValueError('truncated RX payload')
    count = int(f['n'])
    if count < 1 or f['state'] not in ('0','crc','other'):
        raise ValueError('invalid RX counter/state')
    header_crc = f.get('header_crc')
    rx_done = f.get('rx_done')
    metadata_ok = (header_crc is None or (header_crc == 'on' and int(f.get('header_code', '-1')) == 0))
    metadata_ok = metadata_ok and (rx_done is None or rx_done == '1')
    return {'rx_count':count, 'crc_valid':f['state']=='0' and int(f['code'])==0 and metadata_ok,
            'header_crc':header_crc, 'rx_done':rx_done,
            'irq':f.get('irq'), 'buffer_offset':f.get('buffer_offset'),
            'state':f['state'], 'payload_hex':payload.hex(),
            'sequence':bench.seq_of(payload), 'rssi_dbm':float(f['rssi']),
            'snr_db':float(f['snr']), 'frequency_error_hz':float(f['ferr'])}


def summarize_serial(records, first, packets, final_counter, *, tx_complete, collection_complete,
                     allow_unrecognized_rx=False):
    ids, duplicates, foreign, corrupt, crc_fail = set(), 0, 0, 0, 0
    for r in records:
        if not r['crc_valid']:
            crc_fail += 1
            continue
        seq = r['sequence']
        if seq is None or not first <= seq < first+packets:
            foreign += 1
            continue
        if bytes.fromhex(r['payload_hex']) != test_payload(seq):
            corrupt += 1
            continue
        if seq in ids: duplicates += 1
        ids.add(seq)
    counters = [r['rx_count'] for r in records]
    transport_complete = (counters == list(range(1,len(records)+1)) and final_counter == len(records))
    # A known ID with corrupted content is an RF packet error, even if its
    # CRC passed. Preserve the event and count the planned ID as lost.
    # In a controlled conducted delivery test, unknown/empty radio outputs
    # cannot create successful planned IDs. Count them separately while keeping
    # the entire planned denominator. The default still rejects foreign traffic.
    valid = bool(tx_complete and collection_complete and transport_complete
                 and (not foreign or allow_unrecognized_rx))
    return {'measurement_valid':valid, 'per':1-len(ids)/packets if valid else None,
            'planned_packets':packets, 'received_unique':len(ids), 'usable_toa':0,
            'lost':packets-len(ids), 'crc_fail':crc_fail, 'duplicates':duplicates,
            'foreign_packets':foreign, 'payload_mismatches':corrupt,
            'unrecognized_rx_allowed':allow_unrecognized_rx,
            'serial_transport_complete':transport_complete, 'tx_complete':tx_complete,
            'collection_complete':collection_complete,
            'missing_sequences':[n for n in range(first,first+packets) if n not in ids]}


def verify_profile(profile, args, receiving):
    expected = {'sf':str(args.sf), 'cr':f'4/{args.cr+4}', 'sync':'0x12', 'preamble':'12',
                'crc':'on', 'boost':'on', 'receiving':'yes' if receiving else 'no',
                'ldro':'on' if ldro_required(args.sf,args.bw) else 'off'}
    if any(profile.get(k)!=v for k,v in expected.items()):
        raise ValueError(f'Heltec profile mismatch: {profile}')
    if float(profile['bw_khz']) != args.bw or float(profile['freq_mhz']) != 868.1:
        raise ValueError('Heltec frequency/bandwidth mismatch')
    # The added packet counter closes the last-line-loss hole in host logging.
    if 'rx_packets' not in profile:
        raise ValueError('receiver firmware 0.2.0 or later with rx_packets is required')


def measure_serial(c,args,prefix,spp,snr,seed,checkpoint,start_tx,generator_summary):
    import serial
    gap, lead, tail = int(args.gap*args.tx_rate),int(args.tx_rate),int(2*args.tx_rate)
    samples = lead+args.packets*(spp+gap)+tail
    padded = ((samples+262143)//262144)*262144
    max_seconds = 2*padded/args.tx_rate+60
    point = {'snr_db':snr,'seed':seed,'records':[], 'status':'starting',
             'expected_samples':padded,'lead_samples':lead,'tail_samples':tail,
             'started_utc':datetime.now(timezone.utc).isoformat()}
    checkpoint(point)
    raw=args.out.with_name(args.out.stem+f'.snr-{snr:g}.serial.txt')
    port, tx = None, None
    try:
        with raw.open('w',encoding='utf-8') as log:
            port=serial.Serial(args.receiver,115200,timeout=0.05,write_timeout=2)
            time.sleep(2)  # Opening some USB implementations can restart the board.
            reader=LineReader(port)
            def receive(deadline):
                line=reader.readline(deadline)
                if line is not None:
                    log.write(line+'\n'); log.flush()
                    if line.startswith('RX '):
                        point['records'].append(parse_rx(line))
                    if line.startswith(('ERR','FATAL')):
                        raise RuntimeError('receiver: '+line)
                return line
            def command(cmd,expected):
                # Preserve the same open connection and final packet counter
                # if a read-only profile reply is transiently missed.
                for _ in range(3 if cmd=='show' else 1):
                    port.write((cmd+'\n').encode('ascii'))
                    deadline=time.monotonic()+5
                    while time.monotonic()<deadline:
                        line=receive(deadline)
                        if line is not None and line.startswith(expected): return line
                raise TimeoutError('receiver command: '+cmd)
            command('rx stop','OK stopped')
            for cmd in (f'set sf {args.sf}', f'set bw {args.bw:g}', f'set cr {args.cr+4}',
                        'set freq 868.1','set sync 0x12','set preamble 12',
                        'set crc on','set boost on'):
                command(cmd,'OK')
            command('reset count','OK count=0')
            command('rx start','OK receiving')
            point['receiver_profile']=fields(command('show','PROFILE '))
            verify_profile(point['receiver_profile'],args,True)
            if int(point['receiver_profile']['rx_packets']) != 0:
                raise ValueError('receiver had packets before finite TX')
            point['records'].clear()
            tx_out,tx_err=start_tx(c,args,prefix,spp,snr,seed,padded,max_seconds)
            tx=tx_out.channel
            start=time.monotonic(); done=None
            point['status']='collecting'; checkpoint(point)
            while time.monotonic()-start < max_seconds:
                receive(time.monotonic()+0.1)
                if tx.exit_status_ready() and done is None:
                    point['tx_exit_code']=tx.recv_exit_status()
                    point['tx_output']=tx_out.read().decode()+tx_err.read().decode()
                    point['tx_elapsed_s']=time.monotonic()-start
                    point['generator_log']=bench.run(c,f'cat {prefix}.noise.err')
                    point['writer_log']=bench.run(c,f'cat {prefix}.writer.log')
                    point['generator_summary']=generator_summary(point['generator_log'])
                    done=time.monotonic(); checkpoint(point)
                if done is not None and time.monotonic()-done >= 2: break
            if done is None: raise TimeoutError('finite transmitter deadline')
            command('rx stop','OK stopped')
            point['final_receiver_profile']=fields(command('show','PROFILE '))
            verify_profile(point['final_receiver_profile'],args,False)
            summary=point['generator_summary']
            complete=(point['tx_exit_code']==0 and summary.get('complete')==1 and
                      summary.get('packets_completed')==args.packets and
                      summary.get('samples_written')==padded and summary.get('clipped_components')==0 and
                      point['tx_elapsed_s'] >= (lead+args.packets*(spp+gap)-gap)/args.tx_rate-1)
            point.update(summarize_serial(point['records'],args.first_sequence,args.packets,
                         int(point['final_receiver_profile']['rx_packets']),
                         tx_complete=complete,collection_complete=True,
                         allow_unrecognized_rx=args.allow_unrecognized_rx))
            point['status']='complete' if point['measurement_valid'] else 'invalid'
        point['raw_trace']=raw.name
        point['raw_trace_sha256']=hashlib.sha256(raw.read_bytes()).hexdigest()
        checkpoint(point)
        return point
    except BaseException as exc:
        point.update(status='interrupted',error=f'{type(exc).__name__}: {exc}')
        checkpoint(point)
        raise
    finally:
        try:
            if port is not None:
                try: port.write(b'rx stop\n')
                finally: port.close()
        finally:
            try:
                bench.run(c,f'if [ -f {prefix}.producer.pid ]; then kill -TERM $(cat {prefix}.producer.pid) 2>/dev/null || :; fi')
            finally:
                if tx is not None: tx.close()
