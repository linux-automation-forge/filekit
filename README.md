One bash script, three jobs: compress, decompress, and comparefiles or whole directories. Built the way I wished system tools worked —dry-run previews, integrity verification, and guards against the classicfootguns (overwrite accidents, malicious archives).

I built it after getting tired of three separate tools that each trusted metoo much: tar happily extracts archives containing ../evil paths, basiccompressors never verify their own output, and plain diff says nothinguseful about binary files. This fixes all three.

the three commands
compress — with a size-savings receipt
./filekit.sh compress myproject/./filekit.sh compress -l best -n backup.tar.xz notes.md photos/
Auto-picks the best algorithm installed (zstd → xz → gzip → bzip2), showsexactly how many % and bytes you saved, then verifies the archive openscleanly before reporting success. Originals are kept unless you pass--remove and confirm.

decompress — safe by default
./filekit.sh decompress backup.tar.gz --dry-run   # preview members first./filekit.sh decompress backup.tar.gz -o out/
Detects the format by magic bytes (a file lying about its extension getscaught), refuses archives containing ../ or absolute paths (tar-slipattack guard), and extracts into a fresh subfolder instead of dumpingcontents over your current directory.

compare — files or entire directories
./filekit.sh compare old.sh new.sh        # text: +N/-N stats + excerpt./filekit.sh compare v1/ v2/              # dirs: only-in-a / only-in-b / changed./filekit.sh compare a.bin b.bin          # binary: first differing byte
Identical files get a SHA256 verdict. Different files get a useful explanationof HOW they differ. Exit codes are script-friendly: 0 = identical,1 = different, 2 = error — so it composes into pipelines:filekit compare a b || ./notify-me.sh

safety design
Guard	What it stops
dry-run mode (--dry-run)	"wait, what was it about to do?" moments
verify-after-write	corrupted/truncated archives reported instead of trusted
tar-bomb guard	path-traversal archives writing outside the target
keep-source default	compressing never deletes your originals by surprise
overwrite confirms	existing files are never clobbered silently (or use --force)
quick demo (the 60-second tour)
mkdir -p demo && echo "test" > demo/hello.txt./filekit.sh compress demo/./filekit.sh decompress demo.tar.* --dry-run      # safe preview./filekit.sh decompress demo.tar.* -o /tmp/rt./filekit.sh compare demo /tmp/rt/demo            # → IDENTICAL
self-test (offline, temp folder only)
./filekit.sh --selftest
Runs a full round-trip: create → compress → delete → decompress → verifycontent — plus guard and compare checks. Want: pass=12 fail=0.
