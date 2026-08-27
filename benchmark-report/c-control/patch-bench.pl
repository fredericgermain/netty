#!/usr/bin/perl
# Makes rust_echo_bench read a reply to completion instead of giving up on the first
# short read. Upstream treats "read() returned fewer bytes than we sent" as a fatal error
# for that connection, so above roughly one segment every client thread dies within the
# first iteration and the run reports a throughput drawn from an unknown, shrinking number
# of connections. Both transports are measured with this same client.

use strict;
use warnings;

my $path = $ARGV[0] or die "usage: patch-bench.pl <src/main.rs>\n";

my $src = do {
    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    <$fh>;
};

my $old = <<'OLD';
                match stream.read(&mut in_buf) {
                    Err(_) => break,
                    Ok(m) => {
                        if m == 0 || m != length {
                            println!("Read error! length={}", m);
                            break;
                        }
                    }
                };
                sum.inb += 1;
OLD

my $new = <<'NEW';
                let mut got: usize = 0;
                let mut failed = false;
                while got < length {
                    match stream.read(&mut in_buf[got..]) {
                        Err(_) => {
                            failed = true;
                            break;
                        }
                        Ok(0) => {
                            println!("Read error! length={}", got);
                            failed = true;
                            break;
                        }
                        Ok(m) => got += m,
                    }
                }
                if failed {
                    break;
                }
                sum.inb += 1;
NEW

my $count = ($src =~ s/\Q$old\E/$new/);
die "patch-bench.pl: expected exactly 1 replacement, made $count\n" unless $count == 1;

# A refused connection makes the client hang forever rather than fail. Upstream unwraps the
# connect, so the thread panics without ever sending its Count, and the main thread then blocks
# in rx.recv() waiting for a result that cannot arrive: no output, no exit, and a container that
# outlives the timeout that was supposed to bound it. Reporting the refusal and sending an empty
# Count turns an infinite hang into a visible, attributable failure. This touches only the error
# path, so a run in which every connection succeeds behaves exactly as upstream does.
my $old_connect = <<'OLDC';
            let mut stream = TcpStream::connect(&*address).unwrap();
OLDC

my $new_connect = <<'NEWC';
            let mut stream = match TcpStream::connect(&*address) {
                Ok(s) => s,
                Err(e) => {
                    println!("Connect error! {}", e);
                    tx.send(sum).unwrap();
                    return;
                }
            };
            // Without these the client cannot survive a server that stops mid-reply: the worker
            // blocks in read() forever, never looks at the stop flag, and the main thread waits
            // on a Count that is never sent, so the process hangs past any external timeout and
            // outlives the container meant to bound it. A bounded read turns a server stall into
            // a reported error, which is data, instead of a hang, which is nothing. Ten seconds
            // is far longer than any healthy reply on loopback.
            stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            stream.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
NEWC

my $c2 = ($src =~ s/\Q$old_connect\E/$new_connect/);
die "patch-bench.pl: expected exactly 1 connect replacement, made $c2\n" unless $c2 == 1;

open my $out, '>', $path or die "write $path: $!";
print $out $src;
close $out;
print "patch-bench.pl: read-to-completion and connect-failure patches applied\n";
