#!/bin/bash

# ASCII art banner for Hank startup

print_banner() {
    local BLUE='\033[0;34m'
    local YELLOW='\033[1;33m'
    local GREEN='\033[0;32m'
    local NC='\033[0m'

    echo -e "${GREEN}                                                    ${YELLOW}-:${NC}"
    echo -e "${GREEN}                                           ${BLUE}==%@@%%%%%%%%%%@@%++${NC}"
    echo -e "${GREEN}                                         ${BLUE}+@%%%%%%%%%%%%%%%%%%%@%${NC}"
    echo -e "${GREEN}                                       ${BLUE}*%%%%%%%%%%%%%%%%%%%%%%@+${NC}"
    echo -e "${GREEN}                                      ${BLUE}#%%%%%@@%%%##*#*######%@%#${NC}"
    echo -e "${GREEN}                                     ${BLUE}:@%%%@${YELLOW}=------------------${BLUE}#*${NC}"
    echo -e "${GREEN}                                     ${BLUE}-@%%@${YELLOW}----------=+++-------${BLUE}+${NC}"
    echo -e "${GREEN}                                     ${BLUE}:@%%#${YELLOW}---------------------${BLUE}#${NC}"
    echo -e "${GREEN}                                     ${BLUE}:@%@*${YELLOW}--------++=--=++-----${BLUE}*${NC}"
    echo -e "${GREEN}                                     ${BLUE}-@%@+${YELLOW}-=%@@@%@@@#---%%%%%%%@#${NC}"
    echo -e "${GREEN}                                     ${BLUE}=@%@*${YELLOW}*@#--+*==-@@@@@-==*=-%%${NC}"
    echo -e "${GREEN}                                     ${BLUE}*%@@#${YELLOW}-##-+=%.*-@--=@-+-#-**#${NC}"
    echo -e "${GREEN}                                     ${YELLOW}+=**--*#-++*=--%---@--+++=%*${NC}"
    echo -e "${GREEN}                                     ${YELLOW}*=*----+#%%%%#*-----*######+${NC}"
    echo -e "${GREEN}                                     ${YELLOW}.*------------*-----#------=${NC}"
    echo -e "${GREEN}                                      ${YELLOW}*#----------*=#=--*#*-----%${NC}"
    echo -e "${GREEN}                                       ${YELLOW}+----+==*+-----------+*+*-${NC}"
    echo -e "${GREEN}                                       ${YELLOW}-=----------------------*.${NC}"
    echo -e "${GREEN}                                        ${YELLOW}+--------+**++**++**---#${NC}"
    echo -e "${GREEN}                                        ${YELLOW}+-----------=+*++------#${NC}"
    echo -e "${GREEN}                                        ${YELLOW}#=+--------------------*${NC}"
    echo -e "${GREEN}                                        ${YELLOW}+=-#=-----------------++${NC}"
    echo -e "${GREEN}                                        ${YELLOW}:*-----------------=--#${NC}"
    echo -e "${GREEN}                                         ${YELLOW}+---------=+**+=----*${NC}"
    echo -e "${GREEN}                                         ${YELLOW}=------------------=#${NC}"
    echo -e "${GREEN}                                        ${YELLOW}:%*-----------------%=${NC}"
    echo -e "${GREEN}                                      ${YELLOW}=-....:+##*=-------*#-..=+${NC}"
    echo ""
}
