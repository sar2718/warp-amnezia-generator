#!/bin/bash

set -euo pipefail

print_help() {
    cat <<'EOF'
Использование: warp_generator.sh [ОПЦИИ] [PRIVATE_KEY [PUBLIC_KEY]]

Генерирует конфиг(и) Cloudflare WARP для AmneziaVPN/AmneziaWG.

Опции:
  -n, --count N     Сгенерировать N конфигов за один запуск (по умолчанию: 1).
                    Файлы сохраняются в подпапку configs/ рядом со скриптом
                    как WARP.conf, WARP_1.conf, WARP_2.conf и т.д.
                    При N > 1 подробный вывод (vpn://-строка и тело конфига)
                    подавляется, печатается только итоговый список файлов.
  -q, --quiet       Не печатать секретный конфиг и vpn://-строку в терминал.
  -h, --help        Показать эту справку и выйти.

Позиционные аргументы:
  PRIVATE_KEY       Готовый WireGuard приватный ключ (по умолчанию генерируется
                    через wg genkey). Несовместим с --count > 1.
  PUBLIC_KEY        Готовый публичный ключ (по умолчанию вычисляется из
                    приватного через wg pubkey).

Примеры:
  bash warp_generator.sh
  bash warp_generator.sh -n 5
  bash warp_generator.sh --count 3 --quiet
EOF
}

QUIET=0
COUNT=1
POS_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        -q|--quiet)
            QUIET=1
            shift
            ;;
        -n|--count)
            if [[ $# -lt 2 ]]; then
                echo "[ERROR] Опции $1 требуется значение" >&2
                exit 2
            fi
            COUNT="$2"
            shift 2
            ;;
        -n=*|--count=*)
            COUNT="${1#*=}"
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do POS_ARGS+=("$1"); shift; done
            ;;
        -*)
            echo "[ERROR] Неизвестная опция: $1" >&2
            echo "Запустите с --help для справки." >&2
            exit 2
            ;;
        *)
            POS_ARGS+=("$1")
            shift
            ;;
    esac
done

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    echo "[ERROR] --count должен быть целым положительным числом, получено: $COUNT" >&2
    exit 2
fi

if [ "$COUNT" -gt 1 ] && [ "${#POS_ARGS[@]}" -gt 0 ]; then
    echo "[ERROR] Позиционные ключи нельзя использовать вместе с --count > 1" >&2
    echo "        Один ключ нельзя переиспользовать для нескольких регистраций." >&2
    exit 2
fi

set -- "${POS_ARGS[@]+${POS_ARGS[@]}}"

clear
if [ -d "/home/runner" ] || [ -n "${REPL_ID:-}" ]; then
    echo "[INFO] Запуск в Replit — пропускаем установку системных пакетов"
else
    if command -v wg >/dev/null 2>&1 \
        && command -v jq >/dev/null 2>&1 \
        && command -v wget >/dev/null 2>&1 \
        && command -v qrencode >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1; then
        echo "[INFO] Зависимости уже установлены — пропускаем apt"
    else
        echo "[INFO] Не Replit — выполняем установку зависимостей"

        mkdir -p ~/.cloudshell && touch ~/.cloudshell/no-apt-get-warning
        apt update -y && apt install sudo -y
        out="$(sudo apt-get update -y --fix-missing 2>&1)" || {
          echo "$out" | grep -qiE "dl\.yarnpkg\.com|NO_PUBKEY 62D54FD4003F6525|is not signed" || { echo "$out"; exit 1; }
          echo "[WARN] Yarn repo ломает apt update — удаляю yarn.list и повторяю..."
          sudo rm -f /etc/apt/sources.list.d/yarn.list
        }
        sudo apt-get update -y --fix-missing && sudo apt-get install wireguard-tools jq wget qrencode -y --fix-missing
    fi
fi

api="https://api.cloudflareclient.com/v0i1909051800"
ins() { curl -s -H 'User-Agent: okhttp/3.12.1' -H 'Content-Type: application/json' -X "$1" "${api}/$2" "${@:3}"; }
sec() { ins "$1" "$2" -H "Authorization: Bearer $3" "${@:4}"; }

check_json_response() {
    local resp="$1" stage="$2"
    if [ -z "$resp" ] || ! echo "$resp" | jq -e . >/dev/null 2>&1; then
        echo "[ERROR] Cloudflare вернул не-JSON ответ на ${stage} (конфиг ${i} из ${COUNT})." >&2
        echo "        Скорее всего это rate-limit (слишком много регистраций с одного IP)." >&2
        echo "" >&2
        echo "Что делать:" >&2
        echo "  - Подождать и повторить позже (точное время лимита Cloudflare не публикует)." >&2
        echo "  - Сменить IP: другой Codespace / Aeza-сервер / VPS." >&2
        echo "  - Дробить генерацию небольшими пачками с паузами между запусками." >&2
        echo "" >&2
        echo "Ответ сервера (первые 500 символов):" >&2
        echo "${resp:0:500}" >&2
        if [ "${#created_files[@]}" -gt 0 ]; then
            echo "" >&2
            echo "Уже созданные на этом запуске файлы (${#created_files[@]}):" >&2
            for f in "${created_files[@]}"; do echo "  - $f" >&2; done
        fi
        exit 1
    fi
}

I1_VAL="<b 0xc2000000011419fa4bb3599f336777de79f81ca9a8d80d91eeec000044c635cef024a885dcb66d1420a91a8c427e87d6cf8e08b563932f449412cddf77d3e2594ea1c7a183c238a89e9adb7ffa57c133e55c59bec101634db90afb83f75b19fe703179e26a31902324c73f82d9354e1ed8da39af610afcb27e6590a44341a0828e5a3d2f0e0f7b0945d7bf3402feea0ee6332e19bdf48ffc387a97227aa97b205a485d282cd66d1c384bafd63dc42f822c4df2109db5b5646c458236ddcc01ae1c493482128bc0830c9e1233f0027a0d262f92b49d9d8abd9a9e0341f6e1214761043c021d7aa8c464b9d865f5fbe234e49626e00712031703a3e23ef82975f014ee1e1dc428521dc23ce7c6c13663b19906240b3efe403cf30559d798871557e4e60e86c29ea4504ed4d9bb8b549d0e8acd6c334c39bb8fb42ede68fb2aadf00cfc8bcc12df03602bbd4fe701d64a39f7ced112951a83b1dbbe6cd696dd3f15985c1b9fef72fa8d0319708b633cc4681910843ce753fac596ed9945d8b839aeff8d3bf0449197bd0bb22ab8efd5d63eb4a95db8d3ffc796ed5bcf2f4a136a8a36c7a0c65270d511aebac733e61d414050088a1c3d868fb52bc7e57d3d9fd132d78b740a6ecdc6c24936e92c28672dbe00928d89b891865f885aeb4c4996d50c2bbbb7a99ab5de02ac89b3308e57bcecf13f2da0333d1420e18b66b4c23d625d836b538fc0c221d6bd7f566a31fa292b85be96041d8e0bfe655d5dc1afed23eb8f2b3446561bbee7644325cc98d31cea38b865bdcc507e48c6ebdc7553be7bd6ab963d5a14615c4b81da7081c127c791224853e2d19bafdc0d9f3f3a6de898d14abb0e2bc849917e0a599ed4a541268ad0e60ea4d147dc33d17fa82f22aa505ccb53803a31d10a7ca2fea0b290a52ee92c7bf4aab7cea4e3c07b1989364eed87a3c6ba65188cd349d37ce4eefde9ec43bab4b4dc79e03469c2ad6b902e28e0bbbbf696781ad4edf424ffb35ce0236d373629008f142d04b5e08a124237e03e3149f4cdde92d7fae581a1ac332e26b2c9c1a6bdec5b3a9c7a2a870f7a0c25fc6ce245e029b686e346c6d862ad8df6d9b62474fbc31dbb914711f78074d4441f4e6e9edca3c52315a5c0653856e23f681558d669f4a4e6915bcf42b56ce36cb7dd3983b0b1d6fdf0f8efddb68e7ca0ae9dd4570fe6978fbb524109f6ec957ca61f1767ef74eb803b0f16abd0087cf2d01bc1db1c01d97ac81b3196c934586963fe7cf2d310e0739621e8bd00dc23fded18576d8c8f285d7bb5f43b547af3c76235de8b6f757f817683b2151600b11721219212bf27558edd439e73fce951f61d582320e5f4d6c315c71129b719277fc144bbe8ded25ab6d29b6e189c9bd9b16538faf60cc2aab3c3bb81fc2213657f2dd0ceb9b3b871e1423d8d3e8cc008721ef03b28e0ee7bb66b8f2a2ac01ef88df1f21ed49bf1ce435df31ac34485936172567488812429c269b49ee9e3d99652b51a7a614b7c460bf0d2d64d8349ded7345bedab1ea0a766a8470b1242f38d09f7855a32db39516c2bd4bcc538c52fa3a90c8714d4b006a15d9c7a7d04919a1cab48da7cce0d5de1f9e5f8936cffe469132991c6eb84c5191d1bcf69f70c58d9a7b66846440a9f0eef25ee6ab62715b50ca7bef0bc3013d4b62e1639b5028bdf757454356e9326a4c76dabfb497d451a3a1d2dbd46ec283d255799f72dfe878ae25892e25a2542d3ca9018394d8ca35b53ccd94947a8>"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir="$PWD"
configs_dir="${script_dir}/configs"
mkdir -p "${configs_dir}"

created_files=()
last_conf=""
last_vpn_key=""

on_interrupt() {
    echo "" >&2
    echo "[INFO] Прервано пользователем." >&2
    if [ "${#created_files[@]}" -gt 0 ]; then
        echo "Уже созданные на этом запуске файлы:" >&2
        for f in "${created_files[@]}"; do echo "  - $f" >&2; done
    fi
    exit 130
}
trap on_interrupt INT TERM

clear

for ((i = 1; i <= COUNT; i++)); do
    if [ "$i" -eq 1 ]; then
        priv="${1:-$(wg genkey | tr -d '\n')}"
        pub="${2:-$(printf "%s" "${priv}" | wg pubkey | tr -d '\n')}"
    else
        priv=$(wg genkey | tr -d '\n')
        pub=$(printf "%s" "${priv}" | wg pubkey | tr -d '\n')
    fi

    response=$(ins POST "reg" -d "{\"install_id\":\"\",\"tos\":\"$(date -u +%FT%TZ)\",\"key\":\"${pub}\",\"fcm_token\":\"\",\"type\":\"ios\",\"locale\":\"en_US\"}")

    check_json_response "$response" "POST /reg"

    id=$(echo "$response" | jq -r '.result.id')
    token=$(echo "$response" | jq -r '.result.token')
    if [ "$id" = "null" ] || [ -z "$id" ] || [ "$token" = "null" ] || [ -z "$token" ]; then
      echo "[ERROR] Registration failed (конфиг ${i} из ${COUNT}):"
      echo "$response" | jq .
      echo ""
      echo "Cloudflare API недоступен из вашей сети. Варианты обхода:"
      echo "  - Aeza Terminator: https://terminator.aeza.net"
      echo "  - GitHub Codespaces: https://github.com/ImMALWARE/bash-warp-generator/codespaces"
      echo "  - Любой VPS вне РФ через VS Code Remote-SSH"
      if [ "${#created_files[@]}" -gt 0 ]; then
          echo ""
          echo "Уже созданные на этом запуске файлы:"
          for f in "${created_files[@]}"; do echo "  - $f"; done
      fi
      exit 1
    fi
    response=$(sec PATCH "reg/${id}" "$token" -d '{"warp_enabled":true}')
    check_json_response "$response" "PATCH /reg/{id}"
    peer_pub=$(echo "$response" | jq -r '.result.config.peers[0].public_key')
    client_ipv4=$(echo "$response" | jq -r '.result.config.interface.addresses.v4')
    client_ipv6=$(echo "$response" | jq -r '.result.config.interface.addresses.v6')

    if [ -z "$peer_pub" ] || [ "$peer_pub" = "null" ] \
       || [ -z "$client_ipv4" ] || [ "$client_ipv4" = "null" ] \
       || [ -z "$client_ipv6" ] || [ "$client_ipv6" = "null" ]; then
        echo "[ERROR] Cloudflare вернул некорректный ответ на PATCH (конфиг ${i} из ${COUNT}):" >&2
        echo "$response" | jq . >&2
        if [ "${#created_files[@]}" -gt 0 ]; then
            echo "" >&2
            echo "Уже созданные на этом запуске файлы:" >&2
            for f in "${created_files[@]}"; do echo "  - $f" >&2; done
        fi
        exit 1
    fi

    conf=$(cat <<-EOM
	[Interface]
	PrivateKey = ${priv}
	S1 = 0
	S2 = 0
	Jc = 120
	Jmin = 23
	Jmax = 911
	H1 = 1
	H2 = 2
	H3 = 3
	H4 = 4
	MTU = 1280
	I1 = ${I1_VAL}
	Address = ${client_ipv4}, ${client_ipv6}
	DNS = 111.88.96.50, 2a00:ab00:1233:26::50, 111.88.96.51, 2a00:ab00:1233:26::51, 1.1.1.1, 2606:4700:4700::1111, 1.0.0.1, 2606:4700:4700::1001

	[Peer]
	PublicKey = ${peer_pub}
	AllowedIPs = 0.0.0.0/0, ::/0
	Endpoint = 162.159.192.1:500
	EOM
    )

    AWG_JSON=$(jq -n \
        --arg pr "$priv" \
        --arg i1 "$I1_VAL" \
        --arg v4 "$client_ipv4" \
        --arg v6 "$client_ipv6" \
        --arg pp "$peer_pub" \
        --arg cf "$conf" \
        '{
            H1: "1", H2: "2", H3: "3", H4: "4",
            I1: $i1, Jc: "120", Jmax: "911", Jmin: "23", S1: "0", S2: "0",
            allowed_ips: ["0.0.0.0/0", "::/0"],
            client_ip: ($v4 + ", " + $v6),
            client_priv_key: $pr,
            config: ($cf | gsub("\n"; "\r\n")),
            hostName: "162.159.192.1",
            mtu: 1280,
            port: 500,
            server_pub_key: $pp
        }')

    AMNEZIA_JSON=$(jq -n \
        --arg last "$AWG_JSON" \
        --arg name "Cloudflare WARP" \
        '{
            containers: [
                {
                    container: "amnezia-awg",
                    awg: {
                        isThirdPartyConfig: true,
                        last_config: $last,
                        port: "500",
                        transport_proto: "udp"
                    }
                }
            ],
            defaultContainer: "amnezia-awg",
            description: $name,
            hostName: "162.159.192.1"
        }')

    VPN_KEY="vpn://$(echo -n "$AMNEZIA_JSON" | base64 -w 0)"

    conf_file="${configs_dir}/WARP.conf"
    n=1
    while [ -e "${conf_file}" ]; do
        conf_file="${configs_dir}/WARP_${n}.conf"
        n=$((n + 1))
    done
    printf '%s\n' "${conf}" > "${conf_file}"
    created_files+=("${conf_file}")
    if [ "$COUNT" -eq 1 ]; then
        last_conf="${conf}"
        last_vpn_key="${VPN_KEY}"
    fi

    if [ "$COUNT" -gt 1 ]; then
        echo "[${i}/${COUNT}] Сгенерирован: ${conf_file}"
    fi
done

if [ "$COUNT" -eq 1 ]; then
    clear
    if [ "$QUIET" -eq 0 ]; then
        [ -t 1 ] && echo "########## СТРОКА ДЛЯ AMNEZIAVPN ##########"
        echo "$last_vpn_key"
        [ -t 1 ] && echo "########### КОНЕЦ СТРОКИ ДЛЯ AMNEZIAVPN ###########"

        echo -e "\n\n\n"
        [ -t 1 ] && echo "########## НАЧАЛО КОНФИГА ##########"
        echo "${last_conf}"
        [ -t 1 ] && echo "########### КОНЕЦ КОНФИГА ###########"

        echo -e "\n"
    fi
    echo "Импортируйте конфиг в приложение AmneziaVPN! Приложение AmneziaWG не поддерживает этот формат!"
    echo "Конфиг сохранён в файл: ${created_files[0]}"
else
    echo ""
    echo "Сгенерировано ${COUNT} конфигов:"
    for f in "${created_files[@]}"; do
        echo "  - $f"
    done
    echo ""
    echo "Импортируйте конфиги в приложение AmneziaVPN! Приложение AmneziaWG не поддерживает этот формат!"
fi
echo -e "\n"
