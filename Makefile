V=v

build: build-macos build-win

build-macos:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/Triangoli.app/Contents/MacOS/triangoli main.v

build-win:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/triangoli.exe -os windows main.v

build-linux:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/triangoli_linux -os linux main.v
