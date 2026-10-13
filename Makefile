SHELL := /bin/bash
.DEFAULT_GOAL := help

BACKEND ?=
DATABASE_URL ?=
TERMSET ?=
DATASET ?= documents
WORKLOAD ?= topk
QUERY_SHAPE ?= text
QUERY_STYLE ?= disjunction
QUERY_IDS ?=
MODE ?= both
CLIENTS ?= 8
JOBS ?= $(CLIENTS)
DURATION ?= 60
PREWARM ?= 10
BATCH_SIZE ?= 100
THROUGHPUT_START_DELAY ?= 5
TOP_K ?= 10
DENSE_RATIO ?= 0.1
SEED ?= 1592614637
PROGRESS ?= 5
OUTPUT_DIR ?= $(CURDIR)/out

export BACKEND DATABASE_URL TERMSET DATASET WORKLOAD QUERY_SHAPE QUERY_STYLE QUERY_IDS MODE CLIENTS JOBS
export DURATION PREWARM BATCH_SIZE THROUGHPUT_START_DELAY TOP_K DENSE_RATIO SEED PROGRESS OUTPUT_DIR

.PHONY: help run test

help:
	@printf '%s\n' \
	  'make -C local-timed run BACKEND=paradedb DATABASE_URL=postgres://... TERMSET=../datasets/stackexchange/queries.json' \
	  '' \
	  'MODE=both|throughput|latency CLIENTS=8 JOBS=8 DURATION=60 PREWARM=10 BATCH_SIZE=100' \
	  'THROUGHPUT_START_DELAY=5 synchronizes remote workers before measurement' \
	  'DATASET=documents|hn WORKLOAD=topk|count QUERY_SHAPE=text|score_filter|time_sort' \
	  'QUERY_STYLE=conjunction|disjunction|phrase|mixed' \
	  'QUERY_IDS=1,2,3 TOP_K=10 DENSE_RATIO=0.1 SEED=1592614637'

run:
	@./run.sh

test:
	@bash -n run.sh
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_prepare_terms.py
