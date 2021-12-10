V=v

build: build-macos build-win
update:
	tar --create --verbose -a --cd dist --file dist/Triangoli.app.tar.gz Triangoli.app install-libgc.sh
	cp dist/triangoli.exe ../triangoli-web/public/assets/game/
	cp dist/Triangoli.app.tar.gz ../triangoli-web/public/assets/game/

build-macos:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/Triangoli.app/Contents/MacOS/triangoli main.v

build-win:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/triangoli.exe -os windows main.v

build-linux:
	$(V) -gc boehm -prod -skip-unused -show-timings -o dist/triangoli_linux -os linux main.v
