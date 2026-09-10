# Nodo de Salida Residencial

Contraparte de [`Vpsservice-Bash-Free`](../Vpsservice-Bash-Free). Se instala en el
dispositivo que **presta su IP residencial**; el VPS ya trae el otro extremo en
`modules/installers/wg_home.sh`.

```
   VPS (10.77.77.1)  ──── wg-home ────▶  NODO (10.77.77.2)  ────▶  ISP de casa
   marca por UID                         reenvia y NATea            IP residencial
```

El VPS decide **qué usuarios** salen por casa (policy routing por UID con `fwmark 0x77`).
Este script se ocupa de que exista un sitio adonde mandarlos.

---

## Instalación

**PC / máquina virtual (Linux):**
```bash
curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Node-Gateway/main/setup.sh -o /tmp/nodo.sh && sudo bash /tmp/nodo.sh
```

**Termux (con o sin root):**
```bash
pkg install -y curl git
curl -sL https://raw.githubusercontent.com/Juandocoro/Vpsservice-Node-Gateway/main/setup.sh -o nodo.sh && bash nodo.sh
```

Después basta con el comando `nodo`.

---

## Los dos modos

El script detecta el aparato y elige por ti. No es una preferencia estética:
es lo que el sistema operativo permite.

| | **A · WireGuard** | **B · SOCKS inverso** |
|---|---|---|
| Requiere root | sí | **no** |
| Tráfico | TCP + UDP + ICMP | **solo TCP** |
| Rendimiento | nativo (kernel) | menor: SSH cifra sobre TLS |
| Lado VPS | ya listo en `wg_home.sh` | necesita `redsocks` |
| Aparatos | VM, PC, Termux+Magisk | Termux sin root |

### Por qué sin root no hay WireGuard

No es falta de paquetes. Para hacer de nodo de salida hace falta **crear una
interfaz TUN** y **aplicar NAT con iptables**, y Android reserva ambas cosas a
root. La app oficial de WireGuard tampoco sirve: usa `VpnService`, que sólo
*captura* el tráfico del propio teléfono — no puede *reenviar* el que llega
desde el VPS.

La salida es invertir quién abre la conexión. Con `ssh -R <puerto>` (OpenSSH
≥ 7.6) el móvil se conecta **hacia** el VPS y publica allí un SOCKS5 cuyo
extremo de salida es el móvil. El VPS obtiene su IP residencial sin que el
teléfono necesite root, IP fija ni puertos abiertos.

El precio es real y conviene tenerlo presente: **SSH transporta TCP**, así que
UDP e ICMP no viajan. El DNS por UDP seguirá saliendo con la IP del VPS salvo
que fuerces resolución por TCP.

---

## Puesta en marcha

### Modo A — WireGuard

1. **En el VPS:** panel `menu` ▸ GATEWAY RESIDENCIAL ▸ `[1]` instalar,
   luego `[5]` para ver su clave pública.
2. **En el nodo:** `nodo` ▸ `[1]` configurar. Pega IP del VPS, puerto (51820)
   y esa clave pública.
3. El nodo te muestra **su** clave pública.
4. **En el VPS:** `[6]` REGISTRAR CLAVE DEL PC, pega la clave del nodo.
5. **En el nodo:** `[2]` para conectar.
6. **En el VPS:** `[8]` elegir usuarios y `[3]` activar la salida residencial.
7. Comprueba: `[8]` en el nodo y `[11]` en el VPS deben mostrar la misma IP.

### Modo B — SOCKS inverso

1. **En el nodo:** `nodo` ▸ `[1]`. Pide host, puerto SSH, usuario y puerto SOCKS.
2. El nodo genera una clave SSH y escribe la receta del VPS en
   `<config>/vps-setup.txt` (también en `[5]`).
3. **En el VPS:** ejecuta esa receta. Autoriza la clave, instala `redsocks` y
   redirige a él lo que el panel marca con `0x77`.
4. **En el nodo:** `[2]` para conectar.

---

## Arranque automático

`[3]` en el menú. El mecanismo se elige según el aparato:

| Aparato | Mecanismo |
|---|---|
| Linux con systemd | unidad `wghome-node.service` |
| Termux sin root | script en `~/.termux/boot/` — **requiere la app Termux:Boot (F-Droid)** |
| Termux con Magisk | `/data/adb/service.d/` — arranca antes de desbloquear |
| Sin systemd | `@reboot` en cron |

### El guardián

Levantar el túnel una vez al arrancar no basta en un móvil: cambia de wifi a
datos, pierde cobertura, y Android mata procesos en segundo plano. El guardián
(`[4]`) revisa cada 30 s y:

- reconecta si el enlace cayó;
- reinicia el túnel si el handshake lleva más de 240 s sin renovarse;
- **rehace el NAT cuando cambia la interfaz de salida** — sin esto, pasar de
  wifi a datos deja el `MASQUERADE` apuntando a una interfaz muerta.

En Termux toma un `termux-wake-lock` para que el sistema no duerma la CPU.

---

## Uso desde scripts

```bash
bash node.sh --up        # conectar
bash node.sh --down      # desconectar
bash node.sh --status    # "activo (wireguard)" / "caido (socks)"
bash node.sh --guardian  # bucle de reconexión (lo usa el arranque)
```

---

## Dónde vive la configuración

| Aparato | Ruta |
|---|---|
| Linux con root | `/etc/wghome-node/` |
| Termux | `$PREFIX/etc/wghome-node/` |
| Linux sin root | `~/.wghome-node/` |

Contiene `node.conf`, las claves (privada en `600`) y el registro. **Es
independiente del directorio de instalación**: reinstalar o actualizar el
script no borra las claves ya registradas en el VPS.

Si ya hay configuración, `nodo` la adopta y abre el menú directamente; el
asistente sólo aparece la primera vez.

### Equipos configurados a mano

Antes de este script la contraparte se montaba a mano: claves en
`/etc/wireguard/home_private.key`, config en `wg-home.conf` y el servicio
`wg-quick@wg-home`. **Un equipo así ya es un nodo**, y el script lo reconoce.

La detección no busca su propio fichero de configuración —eso daría un falso
negativo— sino **la huella del protocolo: una interfaz WireGuard cuya dirección
es `10.77.77.2`**. Da igual cómo se llame el fichero. También cuenta como
evidencia una unidad `wg-quick@wg-home` activa o la interfaz levantada.

Al encontrarlo, el script enseña lo que hay y ofrece adoptarlo. Adoptar significa:

- **reutiliza tus claves**, nunca las regenera — son las que el VPS tiene
  registradas, y unas nuevas romperían el peer;
- **no reescribe tu `wg-home.conf`**: es tuyo y puede llevar ajustes propios
  (`DNS`, `PostUp`, `MTU`). Los cambios de endpoint se aplican con `wg set`,
  que toca sólo ese campo;
- **respeta `wg-quick`** si ya gestiona la interfaz, en lugar de crear una
  segunda por su cuenta — dos gestores sobre la misma interfaz se pisan;
- **no duplica el NAT** si ya hay un `masquerade` puesto por nftables o por ti.

Puedes decir que no y conservar tu montaje intacto.

---

## Detalles que suelen morder

- **`AllowedIPs = 10.77.77.1/32`**, no `0.0.0.0/0`. El nodo *presta* su salida,
  no la *consume*: con `0.0.0.0/0` el propio aparato mandaría su navegación al
  VPS y se formaría un bucle.
- **No se usa `wg-quick`.** Da por hecho un Linux de escritorio (resolvconf,
  sysctl, rutas en `main`) y se rompe en Android. La interfaz se monta a mano.
- **Policy routing en Android.** La ruta por defecto no está en `main` sino en
  tablas por red (`1021` para datos, `1002` para wifi). Sin las reglas `iif
  wg-home lookup <tabla>` y `to 10.77.77.0/24 lookup main`, el tráfico
  reenviado se pierde y las respuestas no saben volver.
- **MSS clamping.** El túnel recorta el MTU; sin `--clamp-mss-to-pmtu` muchos
  sitios cargan a medias.
- **Todas las reglas llevan el comentario `WGHOME_NODE`**, y se retiran sólo
  ésas: el firewall que ya tuviera el aparato no se toca.
