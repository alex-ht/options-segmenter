#!/usr/bin/env python3
# print a four options grammar to stdout
from math import log

def print_arc(from_node, target_node, label, weight=0.0):
  print("%d\t%d\t%s\t%s\t%f" % (from_node, target_node, label, label, weight))

print_arc(0, 1, "<eps>") # begin end nodes are linked with "<esp>"
nid = 1; # node_id
for opt_num in ["一", "二", "三", "四"]:
  print_arc(nid, nid +1, "<SIL>")
  print_arc(nid+1, nid+2, opt_num)
  print_arc(nid+2, nid+3, "<SIL>")
  print_arc(nid+3, nid+4, "<ANY>")
  print_arc(nid+4, nid+4, "<ANY>", -log(0.9))
  print_arc(nid+4, nid+5, "<eps>", -log(0.1))
  nid = nid+5

print("%d" % (nid))
