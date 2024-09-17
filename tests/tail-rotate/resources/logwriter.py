#!/usr/bin/env python
import argparse
import logging
import time

def main(args):
    file = open(args.outfile, 'a+', buffering=args.file_buffer_max)
    start = time.time_ns()
    bytes_written = 0
    for i in range(0, args.num_lines):
        bytes_written += file.write(f"this is a line {i}\n")

    file.flush()
    stop = time.time_ns()
    seconds = (stop-start)/10**9
    mb = bytes_written/10**6
    logging.info(f"time = {seconds}s, Mb = {mb}, Mb/s={mb/seconds}")

if __name__ == '__main__':
  logging.basicConfig(level=logging.INFO, format="%(asctime)s.%(msecs)03d %(message)s", datefmt='%Y-%m-%dT%H:%M:%S')

  parser = argparse.ArgumentParser(description="Generates a log file")
  parser.add_argument("--num-lines", "-n", default=1000000, help='Number of Lines to write', type=int)
  parser.add_argument("--outfile", "-o", default="./test.txt")
  parser.add_argument("--file-buffer-max", default=1024*10000)
  main(parser.parse_args())