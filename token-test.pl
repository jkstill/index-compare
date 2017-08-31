#!/usr/bin/env perl
#

use strict;
use warnings;
use Data::Dumper;
use Digest::MD5 qw(md5_hex);

use lib 'lib';
use String::Tokenizer;

my $tokenizer = String::Tokenizer->new();

my $string=q{select dummy from dual where dummy = 'Y' and dummy = :my_test_bind};

$tokenizer->tokenize($string);

print "String:\n$string\n";
print join ", " => $tokenizer->getTokens(), "\n";

my @a = $tokenizer->getTokens();

print Dumper(\@a);

s/(').*(')/$1$2/ for @a;

print Dumper(\@a);

my $s = join(' ', @a);

print "new string:\n$s\n";


my $md5Hex = md5_hex($s);

print "MD5: " , Dumper($md5Hex),"\n";

