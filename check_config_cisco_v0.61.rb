#!/usr/bin/env ruby
#check_config_dev v0.61
#!/usr/bin/env ruby
#	
#   This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#	Copyright Alain Pernelle
# Project:  www.alpern.free.fr
# Website: http://www.alpern.free.fr
# Quick documentation: use -h option
# TODO
# - keep name of save file with date.
#Utilisation:
#./check_cisco_dev_v0.61.rb -H <ip_address> -u <username> -p <password> -f <enablepassword> -o <os> [-s ssh]
# os can be ios, catos, h3c, enterasys
# -h, --help    Print detailed help screen
#version 0.2 08/14/2009 add support of catos h3c enterasys network devices 
# need device was setting with username and password
# Bug with Cisco Device Special password charatere
#not completely tested
# it' seems some version of ssh v1.5 are not supported by net/ssh/telnet (update your device)

require 'date'
require 'thread'
require 'rubygems'
require 'optiflag'
require 'net/telnet'
require 'net/ssh/telnet'
now = DateTime.now
mois = now.month
annee = now.year
jour= now.day

# Gestion des options de ligne de commande
# puts "cisco_check_config_v0.1 by alpern  www.alpern.free.fr"
module Example  extend OptiFlagSet
  usage_flag "h","help","?"
  flag "H" do
    long_form "Host"
    description "Host, Cible Equipement Cisco "
  end
  flag "u" do
    long_form "username"
    description "username "
  end
  flag "p" do
    long_form "password"
    description "password "
  end
  flag "f" do
    long_form "enable"
    description "enable password "
  end
  optional_flag "c" do
    long_form "critical"
    description "--critical, default 60,  Critical time (s)"
  end
  flag "o" do
    long_form "os"
    description "--Operating System,values, ios,catos, h3c "
    value_in_set ["ios","catos","h3c","enterasys"]
  end 
  optional_flag "s" do
    long_form "secure"
    description "ssh connection mode"
    value_in_set ["ssh"]
  end
  optional_switch_flag "e" do
    description "extended mode, see the documentation"
  end 
  and_process!
end 

# GET THE ARGV VALUES
if ARGV.flags.e?
  EXTENDED=1
else
  EXTENDED=0
end
# Get Require Arguments 
  username=ARGV.flags.u
  password=ARGV.flags.p
  enablepassword=ARGV.flags.f
  peer=ARGV.flags.H
  os=ARGV.flags.o
# Get Optional arguments
if ARGV.flags.c?
  timeCritical=ARGV.flags.c.to_f
else
  timeCritical=60
end

if ARGV.flags.s?
  mode=ARGV.flags.s
end
begin

fichier=(peer)
directory="/tmp/"
# choix des prompt et commandes specifiques a chaque type d'equipement
case os
   when "catos"
       login_prompt = /[: ]*\z/n
       password_prompt = /[: ]*\z/n
       prompt = /> /n
       mode_privilege = 'enable'
       display_config = 'show conf'
       terminal_lenght = 'set length 0'
   when "ios"
       login_prompt = /[: ]*\z/n
       password_prompt = /[: ]*\z/n
       prompt = /[#>]/n
       mode_privilege = 'enable'
       display_config = 'show conf'
       terminal_lenght = 'term leng 0'
   when "h3c"
       login_prompt = /Username:/
       password_prompt = /Password:/
       prompt = /[>]/
       mode_privilege = 'super'
       display_config = 'dis curr'
       terminal_lenght = 'screen-length disable'
    when "enterasys"
       login_prompt = /Username:/
       password_prompt = /Password:/
       prompt = /[>]/
       mode_privilege = '/n'
       display_config = 'show conf'
       terminal_lenght = 'set length 0'
end

#  localhost.login(username,password) { |c| print c }
# Si le switches ou le router propose directement de taper le password
#  if username == password
#      localhost.waitfor(/[U]nk/n)
#          else
#  end

# sortir les commandes de connexions
# commun à tous les équipements
# connexion a l'equipement
para = {
"Name"                => username,
"Password"            => password,
"LoginPrompt"         => login_prompt,
"PasswordPrompt"      => password_prompt }
if mode == "ssh"
  localhost = Net::SSH::Telnet.new("Host" => peer,
  "Username"	=> username,
  "Password"	=> password,
  "Prompt" => prompt )
  else
  localhost = Net::Telnet::new("Host" => peer,
                              "Timeout" => 25,
                              "Prompt" => prompt )
  localhost.login(para)
end
localhost.puts(mode_privilege)
localhost.cmd(enablepassword)
localhost.cmd(terminal_lenght)
line = localhost.cmd(display_config)
if mode == "ssh"
   localhost.cmd("quit")
else
   localhost.cmd("quit")
   localhost.close
end

# Code de retour vers Nagios voir si line est vide
if line
  totalSize=line.length
  SortieFile = File.new(directory+fichier +"_"+jour.to_s+"-"+mois.to_s+"-"+annee.to_s+".confg", "w")
  SortieFile.puts(line)
  SortieFile.close
  retCode=0
  retCodeLabel="OK"
  puts "#{retCodeLabel}"+"|"+"size="+"#{totalSize}"+"B"
  exit retCode
else
  retCode=2
  retCodeLabel="Critical"
  puts "#{retCodeLabel}"
  exit retCode
end
rescue SystemCallError
  retCode=2
  retCodeLabel="Critical"
  print "#{retCodeLabel}"
  print "Erreur dans le programe"
  exit retCode
## print the script result for nagios
###############################################################
print "#{retCodeLabel}"
exit retCode
end
