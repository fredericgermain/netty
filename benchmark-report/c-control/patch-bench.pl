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

open my $out, '>', $path or die "write $path: $!";
print $out $src;
close $out;
print "patch-bench.pl: read-to-completion patch applied\n";
