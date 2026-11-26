# proctor

proctor prepara un portátil con Windows para un examen. Crea una cuenta de
alumno sin contraseña, limita lo que esa cuenta puede hacer y muestra el
examen en pantalla: una página a pantalla completa en Microsoft Edge que
muestra el PDF que llega por la red. Las respuestas se escriben en papel;
proctor no recoge ni corrige nada.

## Requisitos

- Windows 10 u 11, o Windows Server. PowerShell 5.1, incluido en Windows.
- Microsoft Edge instalado.
- Una carpeta compartida por SMB en la red local.
- Ejecutar la instalación como administrador.

## Instalación

Ejecutar como administrador en cada portátil:

```powershell
.\install.ps1 -Config .\config.json
```

o con parámetros directamente:

```powershell
.\install.ps1 -Server 192.168.5.30 -Share "sidera\Examenes" -DeviceNumber 01 -ExamTitle "Examen de matematicas" -ShareUser proctor-lectura
```

Con `-ShareUser` el instalador pide la contraseña en pantalla (no aparece en
ningún archivo ni en el comando). En scripts se pasa
`-ShareCredential (Get-Credential)`; en ese caso `-ShareUser` no hace falta.

| Parámetro | Descripción | Valor por defecto |
| --- | --- | --- |
| `-Server` | Nombre o IP del servidor con la carpeta compartida. | (obligatorio) |
| `-Share` | Ruta compartida bajo el servidor. También acepta la ruta UNC completa, por ejemplo `\\192.168.5.30\sidera\Examenes`. | (obligatorio) |
| `-UserPrefix` | Prefijo de la cuenta de alumno. La cuenta final es `<prefijo>-<NN>`. | `Alumno` |
| `-DeviceNumber` | Número del equipo, dos dígitos. | (obligatorio) |
| `-ExamTitle` | Título que se muestra en pantalla. | (obligatorio) |
| `-Language` | Idioma de la página: `es` o `en`. | `es` |
| `-ShareUser` | Cuenta del servidor con permiso de lectura sobre la carpeta compartida. La contraseña se pide en pantalla. | (sin credencial) |
| `-ShareCredential` | Credencial ya construida, para ejecuciones con script. | |
| `-Config` | Archivo JSON con los mismos valores (incluye `shareUser`). La contraseña nunca va en el archivo. Los parámetros tienen prioridad. | |

Ejemplo de `config.json` (ver `config.example.json`):

```json
{
  "server": "192.168.5.30",
  "share": "sidera/Examenes",
  "userPrefix": "Alumno",
  "deviceNumber": "01",
  "examTitle": "Examen de matematicas",
  "language": "es"
}
```

La instalación crea la cuenta de alumno sin contraseña, genera su perfil sin
que nadie inicie sesión y deja el inicio de sesión automático apuntando a esa
cuenta. Ejecutarla dos veces produce el mismo resultado.

## Cómo llega el examen

La tarea de sincronización copia cada minuto el PDF más reciente de
`\\<servidor>\<share>\Dispositivo NN` (o `Device NN` en inglés) a
`C:\Kiosk\Exam.pdf`. Para publicar un examen basta con dejar el PDF en la
carpeta del equipo; para retirarlo, borrar el archivo de esa carpeta.

La tarea se ejecuta como SYSTEM y se conecta a la carpeta con una cuenta
propia. El servidor necesita una cuenta de solo lectura sobre la carpeta
compartida (por ejemplo `proctor-lectura`), que se indica con `-ShareUser` o
`shareUser` en la configuración. La contraseña se guarda cifrada con DPAPI en
`C:\ProgramData\proctor\share.cred`, accesible solo para SYSTEM y
Administradores. Sin credencial almacenada la conexión es anónima.

Una carpeta abierta a invitados no sirve: Windows 11 24H2 rechaza por defecto
las conexiones SMB de invitado y anónimas, por lo que el servidor no debe
depender de una carpeta sin autenticación.

## Bloqueo

La cuenta de alumno no tiene acceso a internet: el firewall bloquea todo el
tráfico saliente de esa cuenta. La tarea de sincronización se ejecuta como
SYSTEM, así que la cuenta de alumno no necesita llegar a la carpeta
compartida y tampoco puede leer los exámenes de otros equipos. Edge aplica políticas que deshabilitan descargas, impresión,
el menú contextual y el inicio de sesión.

En Windows Pro, Education y Enterprise la cuenta funciona como quiosco de
aplicación única mediante Assigned Access: Edge abre
`file:///C:/Kiosk/index.html` a pantalla completa.

En Windows Home, que no tiene Assigned Access, se aplican restricciones del
registro (sin Ejecutar, sin símbolo del sistema, sin Administrador de tareas)
y Edge arranca en modo quiosco al iniciar sesión.

El instalador imprime la edición que encontró y la vía que aplicó.

## Desinstalación

```powershell
.\uninstall.ps1 -UserName Alumno-01 -Force
```

o con los mismos parámetros de la instalación (`-Config`, `-UserPrefix`,
`-DeviceNumber`). Quita la tarea, las reglas de firewall, las políticas,
Assigned Access, el inicio automático de sesión, `C:\Kiosk`,
`C:\ProgramData\proctor` (incluida la credencial), la cuenta de alumno y su
perfil. Sin `-Force` pide confirmación. Funciona también después de una
instalación incompleta.

## Desarrollo

Las comprobaciones se ejecutan con mise:

```
mise run check
```

`check` lanza `lint` (PSScriptAnalyzer) y `test` (Pester). Necesitan `pwsh`
en el PATH; las tareas instalan los módulos que falten en el usuario actual.
