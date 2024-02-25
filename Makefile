all: simulate

simulate: a.out
	./a.out

a.out: TestBF.bo
	bsc -sim -e mkTestBF

TestBF.bo: TestBF.bsv BF.bsv
	bsc -sim -g mkTestBF -u TestBF.bsv
