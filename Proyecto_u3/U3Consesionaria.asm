; ============================================================================
; Lenguajes de Interfaz - Unidad 3 (version refactorizada de la Unidad 2)
; Proyecto: Ventas e inventario de una CONCESIONARIA DE AUTOS DEPORTIVOS
; MASM x86 (32 bits) + Irvine32
;
; Se conservan funciones, validaciones y la regla del negocio:
;   DESCUENTO POR CANTIDAD: 3 o mas unidades del mismo modelo -> 10% de
;   descuento sobre el importe base (division entera, sin fracciones).
;
; Mejoras de esta version
;   - PROCEDIMIENTOS nuevos: AskCode, AskName, AskPrice, AskStock, AskQty,
;     AskUInt (captura + validacion + mensaje de error), FindCodeIn (busqueda
;     compartida), CalcSale y CalcDiscount (calculo de importes), ShowSale,
;     DoLoad, ConfirmExit, ReadTextFile, GetField/NextField/LastField.
;   - MACROS: mPrint, mPrompt, mReject, mFail, mCallOn, mLoad64, mStore64,
;     mLoad32, mPrintAmtLine, mPutChar, mClearMem, mCopyMem,
;     mDigitVal, mJNotBetween y, con etiqueta interna declarada con LOCAL,
;     mToLower y mRequireProducts.
;   - USES: los procedimientos que alteran registros ajenos los conservan con
;     PROC USES; los registros de salida (EAX, ESI, EDI segun el caso) NO van
;     en USES. MASM inserta PUSH al entrar y POP antes de cada RET, y los POP
;     no alteran las banderas (CF/ZF de salida se conservan).
;   - Menu con tabla de procedimientos (menuTable) en lugar de CMP/JE en cadena.
;
; Datos: arreglo de 10 registros de 44 bytes
;   +0 Codigo (8) | +8 Nombre (26) | +34 relleno (2) | +36 Precio DWORD
;   (centavos) | +40 Existencia DWORD
; Archivo inventario.txt: una linea por producto
;   CODIGO;NOMBRE;PRECIO;EXISTENCIA  (terminada en CR LF)
; Importes de 64 bits: dos DWORD (parte baja, parte alta) o EDX:EAX.
; (Texto sin acentos para evitar problemas de codificacion en la consola.)
; ============================================================================
INCLUDE Irvine32.inc

; ---------------------------- Constantes -----------------------------------
MAXPROD       EQU 10
RECSIZE       EQU 44
OFF_CODE      EQU 0
OFF_NAME      EQU 8
OFF_PRICE     EQU 36
OFF_STOCK     EQU 40
MAXNAME       EQU 25
MAXPRICE      EQU 1000000000    ; $10,000,000.00 en centavos
MAXPESOS      EQU 10000000
MAXDIGITS     EQU 8             ; digitos enteros permitidos en el precio
MAXSTOCK      EQU 100
MAXIN         EQU 40            ; maximo de caracteres por captura/campo
FILEBUFSIZE   EQU 1024
BAD_HANDLE    EQU 0FFFFFFFFh
DISC_MINQTY   EQU 3             ; regla: cantidad minima para descuento
DISC_PCT      EQU 10            ; regla: porcentaje de descuento
MENU_ITEMS    EQU 8
SEP           EQU 3Bh           ; ';' separador del archivo de texto

; ============================================================================
; MACROS
; ============================================================================

; mPrint: muestra la cadena msg.            Modifica: EDX (y lo que modifique WriteString)
mPrint MACRO msg
    mov edx, OFFSET msg
    call WriteString
ENDM

; mPrompt: muestra msg y captura la respuesta en inBuf. Salida: EAX = longitud.
mPrompt MACRO msg
    mov edx, OFFSET msg
    call Ask
ENDM

; mReject: muestra un mensaje y REGRESA al llamador (ret).
mReject MACRO msg
    mPrint msg
    ret
ENDM

; mFail: muestra un mensaje y REGRESA con CF=1 (STC va despues de la salida).
mFail MACRO msg
    mPrint msg
    stc
    ret
ENDM

; mCallOn: ESI = OFFSET buffer y llama a routine (validadores/convertidores).
mCallOn MACRO buffer, routine
    mov esi, OFFSET buffer
    call routine
ENDM

; mLoad64 / mStore64: EDX:EAX <-> importe de 64 bits (bajo, alto) en memoria.
mLoad64 MACRO var
    mov eax, var
    mov edx, var+4
ENDM

mStore64 MACRO var
    mov var, eax
    mov var+4, edx
ENDM

; mLoad32: EDX:EAX = valor de 32 bits (extendido con ceros).
mLoad32 MACRO src
    mov eax, src
    xor edx, edx
ENDM

; mPrintAmtLine: etiqueta + importe de 64 bits (var) como $X.XX MXN + salto de linea.
mPrintAmtLine MACRO msg, var
    mPrint msg
    mLoad64 var
    call PrintMXN
    call Crlf
ENDM

; mPutChar: escribe un caracter en [EDI] y avanza EDI.
mPutChar MACRO ch
    mov BYTE PTR [edi], ch
    inc edi
ENDM

; mClearMem / mCopyMem: llenan con 0 o copian count bytes (REP STOSB/MOVSB).
; Modifican: EAX(AL), ECX, ESI, EDI, DF=0.
mClearMem MACRO dest, count
    cld
    mov edi, OFFSET dest
    mov ecx, count
    xor al, al
    rep stosb
ENDM

mCopyMem MACRO dest, src, count
    cld
    mov esi, OFFSET src
    mov edi, OFFSET dest
    mov ecx, count
    rep movsb
ENDM

; mDigitVal: reg = reg - '0' y salta a badLabel si no era un digito.
mDigitVal MACRO reg, badLabel
    sub reg, '0'
    cmp reg, 9
    ja badLabel
ENDM

; mJNotBetween: salta a target si reg esta fuera de [lo, hi] (sin signo).
mJNotBetween MACRO reg, lo, hi, target
    cmp reg, lo
    jb target
    cmp reg, hi
    ja target
ENDM

; mToLower: convierte a minuscula el caracter en reg8 (solo si es A-Z).
; Tiene etiqueta interna y se usa en varios puntos: se declara con LOCAL.
mToLower MACRO reg8
    LOCAL notUpper
    cmp reg8, 'A'
    jb notUpper
    cmp reg8, 'Z'
    ja notUpper
    or reg8, 20h
notUpper:
ENDM

; mRequireProducts: si no hay productos muestra aviso y regresa al llamador.
; Tiene etiqueta interna y se usa en 4 procedimientos: LOCAL.
mRequireProducts MACRO
    LOCAL haveItems
    cmp prodCount, 0
    jne haveItems
    mReject eNone
haveItems:
ENDM

.data
; ---------------------------- Datos del programa ---------------------------
inventory   BYTE MAXPROD*RECSIZE DUP(0)  ; catalogo en memoria
tmpInv      BYTE MAXPROD*RECSIZE DUP(0)  ; catalogo temporal (carga de archivo)
newRec      BYTE RECSIZE DUP(0)          ; registro temporal (alta)
prodCount   DWORD 0
tmpCount    DWORD 0
dirty       DWORD 0                      ; 1 = hay cambios sin guardar
selRec      DWORD 0                      ; puntero al registro seleccionado
txtPtr      DWORD 0                      ; posicion actual al leer el texto
; Importes de 64 bits: primer DWORD = parte baja, segundo = parte alta
income      DWORD 0, 0                   ; ingresos de la sesion (centavos)
baseAmt     DWORD 0, 0
discAmt     DWORD 0, 0
finalAmt    DWORD 0, 0
totValue    DWORD 0, 0                   ; valor total del inventario
hFile       DWORD 0
bytesReq    DWORD 0
bytesDone   DWORD 0
inBuf       BYTE 64 DUP(0)               ; entrada del usuario
drainBuf    BYTE 64 DUP(0)               ; para vaciar entradas demasiado largas
fldBuf      BYTE 64 DUP(0)               ; campo extraido del archivo de texto
numBuf      BYTE 40 DUP(0)               ; cadena de numero convertido
fileBuf     BYTE FILEBUFSIZE DUP(0)      ; buffer de archivo
fileName    BYTE "inventario.txt",0

; Tabla de procedimientos del menu (opcion 1..8 -> indice 0..7)
menuTable   DWORD OFFSET DoRegister, OFFSET DoList, OFFSET DoSearch,
                  OFFSET DoReceive, OFFSET DoSell, OFFSET DoSummary,
                  OFFSET SaveCatalog, OFFSET DoLoad

; ---------------------------- Mensajes -------------------------------------
msgBanner BYTE 0Dh,0Ah,"=== CONCESIONARIA DE AUTOS DEPORTIVOS - Ventas e Inventario ===",0Dh,0Ah,
                "Regla: 10% de descuento desde 3 unidades del mismo modelo.",0Dh,0Ah,0
msgMenu   BYTE 0Dh,0Ah,"----------------- MENU -----------------",0Dh,0Ah,
                "1. Registrar auto",0Dh,0Ah,
                "2. Mostrar inventario",0Dh,0Ah,
                "3. Buscar por codigo",0Dh,0Ah,
                "4. Recibir mercancia",0Dh,0Ah,
                "5. Vender",0Dh,0Ah,
                "6. Resumen",0Dh,0Ah,
                "7. Guardar catalogo",0Dh,0Ah,
                "8. Cargar catalogo",0Dh,0Ah,
                "0. Salir",0Dh,0Ah,0
pOpt      BYTE "Opcion: ",0
pCode     BYTE "Codigo (formato ABC-123): ",0
pName     BYTE "Nombre del auto (1 a 25 caracteres): ",0
pPrice    BYTE "Precio en MXN (ej. 3500000.50): ",0
pStock    BYTE "Existencia inicial (0 a 100): ",0
pQty      BYTE "Cantidad a vender (entero > 0): ",0
pRecv     BYTE "Unidades recibidas (entero > 0): ",0
pExit     BYTE "Hay cambios sin guardar. S=guardar y salir, N=salir sin guardar, otra tecla=cancelar: ",0
pLoadAsk  BYTE "Hay cambios sin guardar; cargar los descartara. Continuar (S/N)? ",0

eOpt      BYTE "Opcion invalida.",0Dh,0Ah,0
eEmpty    BYTE "Error: el dato esta vacio.",0Dh,0Ah,0
eCode     BYTE "Error: codigo invalido (3 letras mayusculas, guion, 3 digitos).",0Dh,0Ah,0
eDup      BYTE "Error: ya existe un producto con ese codigo.",0Dh,0Ah,0
eNotFound BYTE "Error: no existe un producto con ese codigo.",0Dh,0Ah,0
eName     BYTE "Error: nombre vacio o invalido (1 a 25 caracteres imprimibles, sin ';').",0Dh,0Ah,0
ePrice    BYTE "Error: precio invalido (0.01 a 10000000.00, hasta 2 decimales, sin simbolos).",0Dh,0Ah,0
eStock    BYTE "Error: existencia invalida (entero de 0 a 100).",0Dh,0Ah,0
eQty      BYTE "Error: la cantidad debe ser un entero mayor que cero.",0Dh,0Ah,0
eFull     BYTE "Error: el inventario esta lleno (maximo 10 productos).",0Dh,0Ah,0
eNone     BYTE "No hay productos registrados.",0Dh,0Ah,0
eExceed   BYTE "Error: la existencia resultante superaria 100 unidades.",0Dh,0Ah,0
eNoStock  BYTE "Venta rechazada: existencias insuficientes.",0Dh,0Ah,0
eOvf      BYTE "Error: desbordamiento en el calculo; operacion rechazada.",0Dh,0Ah,0
eNoFile   BYTE "No se encontro inventario.txt; se conserva el catalogo actual.",0Dh,0Ah,0
eRead     BYTE "Error al leer el archivo; se conserva el catalogo actual.",0Dh,0Ah,0
eBadFile  BYTE "Archivo invalido o danado; se conserva el catalogo actual.",0Dh,0Ah,0
eCreate   BYTE "Error: no se pudo crear inventario.txt.",0Dh,0Ah,0
eWrite    BYTE "Error: no se escribieron todos los bytes del archivo.",0Dh,0Ah,0

okReg     BYTE "Auto registrado correctamente.",0Dh,0Ah,0
okRecv    BYTE "Mercancia recibida. Nueva existencia: ",0
okSave    BYTE "Catalogo guardado en inventario.txt.",0Dh,0Ah,0
okLoad    BYTE "Catalogo cargado. Productos: ",0
tSale     BYTE "Venta aceptada.",0Dh,0Ah,0
tBase     BYTE "  Importe base:  ",0
tDisc     BYTE "  Descuento por cantidad (10%): -",0
tNoDisc   BYTE "  (sin descuento: menos de 3 unidades)",0Dh,0Ah,0
tFinal    BYTE "  Importe final: ",0
tHeader   BYTE "Codigo  | Nombre | Precio | Existencia",0Dh,0Ah,0
tUnits    BYTE "Unidades disponibles: ",0
tValue    BYTE "Valor total del inventario: ",0
tIncome   BYTE "Ingresos acumulados de la sesion: ",0
tBye      BYTE "Hasta luego.",0Dh,0Ah,0
sSep      BYTE " | ",0
sUds      BYTE " uds",0

.code
; ============================================================================
; main: menu repetitivo. Las opciones 1..8 se despachan con menuTable.
; ============================================================================
main PROC
    mPrint msgBanner
    call LoadCatalog                ; intenta recuperar el catalogo al iniciar
mn_loop:
    mPrint msgMenu
    mPrompt pOpt
    mCallOn inBuf, ParseUInt
    jc mn_bad
    test eax, eax
    jz mn_exit                      ; 0 = salir
    cmp eax, MENU_ITEMS
    ja mn_bad
    dec eax                         ; opcion 1..8 -> indice 0..7
    call menuTable[eax*4]           ; llamada indirecta al procedimiento
    jmp mn_loop
mn_bad:
    mPrint eOpt
    jmp mn_loop
mn_exit:
    call ConfirmExit
    test eax, eax
    jz mn_loop                      ; el usuario cancelo la salida
    mPrint tBye
    exit
main ENDP

; ============================================================================
; CAPTURA Y VALIDACION
; ============================================================================

; ----------------------------------------------------------------------------
; GetLine: captura una linea con ReadString y vacia el exceso si se pasa.
; Entrada : EDX = OFFSET del buffer (minimo MAXIN+1 bytes)
; Salida  : EAX = caracteres capturados (MAXIN = "demasiado largo")
; Modifica: EAX, banderas.   Conserva: ECX, EDX (USES)
; ----------------------------------------------------------------------------
GetLine PROC USES ecx edx
    mov ecx, MAXIN                  ; ECX = maximo de caracteres a leer
    call ReadString                 ; EAX = caracteres leidos
    cmp eax, MAXIN
    jb gl_done
gl_drain:                           ; se lleno: descartar lo que sobre
    mov edx, OFFSET drainBuf
    mov ecx, MAXIN
    call ReadString
    cmp eax, MAXIN
    jae gl_drain
    mov eax, MAXIN
gl_done:
    ret
GetLine ENDP

; ----------------------------------------------------------------------------
; Ask: muestra un mensaje y captura la respuesta en inBuf.
; Entrada : EDX = OFFSET del mensaje
; Salida  : EAX = longitud capturada; texto en inBuf
; Modifica: EAX, EDX, banderas.
; ----------------------------------------------------------------------------
Ask PROC
    call WriteString
    mov edx, OFFSET inBuf
    call GetLine
    ret
Ask ENDP

; ----------------------------------------------------------------------------
; AskYesNo: pregunta S/N.
; Entrada : EDX = OFFSET del mensaje
; Salida  : EAX = 1 si respondio S/s, 0 en otro caso
; Modifica: EAX, EDX, banderas.
; ----------------------------------------------------------------------------
AskYesNo PROC
    call Ask
    cmp eax, 1
    jne yn_no
    mov al, [inBuf]
    mToLower al
    cmp al, 's'
    jne yn_no
    mov eax, 1
    ret
yn_no:
    xor eax, eax
    ret
AskYesNo ENDP

; ----------------------------------------------------------------------------
; ParseUInt: cadena de digitos -> entero sin signo (acumulado*10 + digito).
; Entrada : ESI = cadena terminada en 00h
; Salida  : EAX = valor; CF=1 si esta vacia, tiene caracteres no permitidos
;           o desborda 32 bits
; Modifica: EAX, banderas.   Conserva: EBX, ECX, EDX, ESI (USES)
; ----------------------------------------------------------------------------
ParseUInt PROC USES ebx ecx edx esi
    xor eax, eax                    ; acumulador
    xor ecx, ecx                    ; contador de digitos
    mov ebx, 10
pu_next:
    movzx edx, BYTE PTR [esi]
    test edx, edx
    jz pu_end
    mDigitVal edx, pu_bad           ; ASCII -> 0..9 o error
    push edx                        ; MUL destruye EDX: guardar el digito
    mul ebx                         ; EDX:EAX = EAX * 10
    pop edx
    jc pu_bad                       ; no cabe en 32 bits
    add eax, edx
    jc pu_bad
    inc ecx
    inc esi
    jmp pu_next
pu_end:
    test ecx, ecx
    jz pu_bad                       ; cadena vacia
    clc
    ret
pu_bad:
    stc
    ret
ParseUInt ENDP

; ----------------------------------------------------------------------------
; ParsePrice: "3500000.50" / "185" / "12.05" -> centavos enteros. Acepta pesos
;   enteros o punto con 1 o 2 decimales (hasta 8 digitos enteros); rechaza
;   simbolos, separadores de miles, tercer decimal, ".50", "185." y valores
;   fuera de 0.01 a 10000000.00.
; Entrada : ESI = cadena terminada en 00h
; Salida  : EAX = centavos (1..1000000000); CF=1 si es invalido
; Modifica: EAX, banderas.   Conserva: ECX, EDX, ESI (USES)
; ----------------------------------------------------------------------------
ParsePrice PROC USES ecx edx esi
    xor eax, eax                    ; pesos acumulados
    xor ecx, ecx                    ; digitos enteros
pp_int:
    movzx edx, BYTE PTR [esi]
    cmp edx, '.'
    je pp_intdone
    test edx, edx
    jz pp_intdone
    mDigitVal edx, pp_bad
    cmp ecx, MAXDIGITS              ; maximo 8 digitos enteros
    jae pp_bad
    imul eax, eax, 10               ; max 99,999,999: cabe en 32 bits
    add eax, edx
    inc ecx
    inc esi
    jmp pp_int
pp_intdone:                         ; EDX = '.' o 00h (fin)
    test ecx, ecx
    jz pp_bad                       ; ".50" o cadena vacia
    cmp eax, MAXPESOS               ; evita desbordar al multiplicar por 100
    ja pp_bad
    imul eax, eax, 100              ; pesos -> centavos
    test edx, edx
    jz pp_range                     ; sin punto: pesos enteros
    inc esi                         ; saltar el punto
    movzx edx, BYTE PTR [esi]       ; primer decimal (obligatorio)
    mDigitVal edx, pp_bad           ; tambien rechaza "185."
    imul edx, edx, 10               ; decimas = digito*10 centavos
    add eax, edx
    inc esi
    movzx edx, BYTE PTR [esi]       ; segundo decimal (opcional)
    test edx, edx
    jz pp_range
    mDigitVal edx, pp_bad
    add eax, edx                    ; centesimas = digito centavos
    inc esi
    cmp BYTE PTR [esi], 0           ; un tercer caracter = rechazo
    jne pp_bad
pp_range:
    cmp eax, 1
    jb pp_bad
    cmp eax, MAXPRICE
    ja pp_bad
    clc
    ret
pp_bad:
    stc
    ret
ParsePrice ENDP

; ----------------------------------------------------------------------------
; ValidateCode: formato ABC-123 (3 mayusculas, guion, 3 digitos).
; Entrada : ESI = cadena terminada en 00h
; Salida  : CF=1 si es invalido
; Modifica: EAX (AL), banderas.   Conserva: ECX, ESI (USES)
; ----------------------------------------------------------------------------
ValidateCode PROC USES ecx esi
    mov ecx, 3
vc_let:
    mov al, [esi]
    mJNotBetween al, 'A', 'Z', vc_bad
    inc esi
    loop vc_let
    cmp BYTE PTR [esi], '-'
    jne vc_bad
    inc esi
    mov ecx, 3
vc_dig:
    mov al, [esi]
    mJNotBetween al, '0', '9', vc_bad
    inc esi
    loop vc_dig
    cmp BYTE PTR [esi], 0           ; no debe haber mas caracteres
    jne vc_bad
    clc
    ret
vc_bad:
    stc
    ret
ValidateCode ENDP

; ----------------------------------------------------------------------------
; ValidateName: 1 a 25 caracteres imprimibles, sin iniciar en espacio y sin
;               ';' (separador del archivo).
; Entrada : ESI = cadena terminada en 00h
; Salida  : EAX = longitud; CF=1 si es invalido
; Modifica: EAX, banderas.   Conserva: ECX, EDX, ESI (USES)
; ----------------------------------------------------------------------------
ValidateName PROC USES ecx edx esi
    xor ecx, ecx
    cmp BYTE PTR [esi], ' '
    je vn_bad
vn_next:
    mov dl, [esi]
    test dl, dl
    jz vn_end
    mJNotBetween dl, 20h, 7Eh, vn_bad
    cmp dl, SEP
    je vn_bad
    inc ecx
    cmp ecx, MAXNAME
    ja vn_bad                       ; mas de 25: rechazar
    inc esi
    jmp vn_next
vn_end:
    test ecx, ecx
    jz vn_bad
    mov eax, ecx
    clc
    ret
vn_bad:
    stc
    ret
ValidateName ENDP

; ----------------------------------------------------------------------------
; AskUInt: pide un entero (sin validar rango).
; Entrada : EDX = OFFSET del mensaje
; Salida  : EAX = valor; CF=1 si es invalido (sin mensaje)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskUInt PROC USES esi
    call Ask
    mCallOn inBuf, ParseUInt
    ret
AskUInt ENDP

; ----------------------------------------------------------------------------
; AskCode: pide un codigo y valida vacio/formato.
; Salida  : CF=0 y codigo valido en inBuf; CF=1 si es invalido (el mensaje
;           de error ya se mostro)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskCode PROC USES esi
    mPrompt pCode
    test eax, eax
    jz ac_empty
    mCallOn inBuf, ValidateCode
    jc ac_fmt
    ret                             ; CF=0 (lo dejo ValidateCode)
ac_empty:
    mFail eEmpty
ac_fmt:
    mFail eCode
AskCode ENDP

; ----------------------------------------------------------------------------
; AskName: pide el nombre del auto y lo valida.
; Salida  : EAX = longitud, texto en inBuf; CF=1 si es invalido (mensaje mostrado)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskName PROC USES esi
    mPrompt pName
    mCallOn inBuf, ValidateName
    jc an_bad
    ret
an_bad:
    mFail eName
AskName ENDP

; ----------------------------------------------------------------------------
; AskPrice: pide el precio en MXN y lo convierte a centavos.
; Salida  : EAX = centavos; CF=1 si es invalido (mensaje mostrado)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskPrice PROC USES esi
    mPrompt pPrice
    mCallOn inBuf, ParsePrice
    jc ap_bad
    ret
ap_bad:
    mFail ePrice
AskPrice ENDP

; ----------------------------------------------------------------------------
; AskStock: pide una existencia (0 a MAXSTOCK).
; Salida  : EAX = existencia; CF=1 si es invalida (mensaje mostrado)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskStock PROC USES esi
    mPrompt pStock
    mCallOn inBuf, ParseUInt
    jc as_bad
    cmp eax, MAXSTOCK
    ja as_bad
    clc                             ; CMP pudo dejar CF=1: limpiarla
    ret
as_bad:
    mFail eStock
AskStock ENDP

; ----------------------------------------------------------------------------
; AskQty: pide una cantidad entera mayor que cero (ventas y entradas).
; Entrada : EDX = OFFSET del mensaje
; Salida  : EAX = cantidad; CF=1 si es invalida (mensaje mostrado)
; Modifica: EAX, EDX, banderas.   Conserva: ESI (USES)
; ----------------------------------------------------------------------------
AskQty PROC USES esi
    call Ask
    mCallOn inBuf, ParseUInt
    jc aq_bad
    test eax, eax
    jz aq_bad                       ; cero no es valido
    clc
    ret
aq_bad:
    mFail eQty
AskQty ENDP

; ============================================================================
; BUSQUEDA
; ============================================================================

; ----------------------------------------------------------------------------
; CmpCode: compara 7 bytes de dos codigos.
; Entrada : ESI, EDI = direcciones de los codigos
; Salida  : ZF=1 si son iguales
; Modifica: solo banderas.   Conserva: ECX, ESI, EDI (USES)
; ----------------------------------------------------------------------------
CmpCode PROC USES ecx esi edi
    cld
    mov ecx, 7
    repe cmpsb
    ret                             ; los POP del epilogo no alteran ZF
CmpCode ENDP

; ----------------------------------------------------------------------------
; FindCodeIn: busca un codigo en un arreglo de registros (recorrido con ESI).
;             Lo usan la busqueda normal y la deteccion de duplicados al
;             cargar el archivo.
; Entrada : EDX = OFFSET del codigo buscado, ESI = primer registro,
;           ECX = numero de registros
; Salida  : CF=0 y ESI = registro encontrado; CF=1 si no existe (ESI sin valor)
; Modifica: ESI, banderas.   Conserva: ECX, EDI, EDX (USES ECX EDI)
; ----------------------------------------------------------------------------
FindCodeIn PROC USES ecx edi
    test ecx, ecx
    jz fi_no
fi_loop:
    mov edi, edx
    call CmpCode
    je fi_yes
    add esi, RECSIZE                ; siguiente registro
    dec ecx
    jnz fi_loop
fi_no:
    stc
    ret
fi_yes:
    clc
    ret
FindCodeIn ENDP

; ----------------------------------------------------------------------------
; FindByCode: busca un codigo en el catalogo.
; Entrada : EDX = OFFSET del codigo buscado
; Salida  : CF=0 y ESI = registro; CF=1 si no existe
; Modifica: ESI, banderas.   Conserva: ECX, EDX (USES ECX)
; ----------------------------------------------------------------------------
FindByCode PROC USES ecx
    mov esi, OFFSET inventory
    mov ecx, prodCount
    call FindCodeIn
    ret
FindByCode ENDP

; ----------------------------------------------------------------------------
; AskCodeFind: pide un codigo, valida el formato y lo busca.
; Salida  : CF=0 y ESI = registro; CF=1 si hubo error (mensaje ya mostrado)
; Modifica: EAX, EDX, ESI, banderas.
; ----------------------------------------------------------------------------
AskCodeFind PROC
    call AskCode
    jc acf_out                      ; formato incorrecto (ya reportado)
    mov edx, OFFSET inBuf
    call FindByCode
    jc acf_nf
acf_out:
    ret
acf_nf:
    mFail eNotFound
AskCodeFind ENDP

; ============================================================================
; ARITMETICA DE 64 BITS
; ============================================================================

; ----------------------------------------------------------------------------
; Div64: divide un numero de 64 bits entre uno de 32 bits (dos DIV).
; Entrada : EDX:EAX = dividendo, EBX = divisor (distinto de 0)
; Salida  : EDX:EAX = cociente, ECX = residuo
; Modifica: EAX, EDX, ECX, banderas.   Conserva: EBX, ESI (USES ESI)
; ----------------------------------------------------------------------------
Div64 PROC USES esi
    mov esi, eax                    ; guardar parte baja
    mov eax, edx                    ; parte alta
    xor edx, edx
    div ebx                         ; EAX = cociente alto, EDX = residuo
    push eax                        ; guardar cociente alto
    mov eax, esi                    ; EDX:EAX = residuo:parte baja
    div ebx                         ; EAX = cociente bajo, EDX = residuo
    mov ecx, edx
    pop edx                         ; EDX = cociente alto
    ret
Div64 ENDP

; ----------------------------------------------------------------------------
; Mul64: multiplica un numero de 64 bits por uno de 32 bits (dos MUL).
; Entrada : EDX:EAX = multiplicando, EBX = multiplicador
; Salida  : EDX:EAX = producto; CF=1 si no cabe en 64 bits
; Modifica: EAX, EDX, banderas.   Conserva: EBX, ECX, ESI (USES ECX ESI)
; ----------------------------------------------------------------------------
Mul64 PROC USES ecx esi
    mov esi, edx                    ; ESI = parte alta
    mul ebx                         ; EDX:EAX = parte baja * EBX
    mov ecx, edx                    ; acarreo hacia la parte alta
    push eax                        ; resultado bajo
    mov eax, esi
    mul ebx                         ; EDX:EAX = parte alta * EBX
    jc m6_ovf                       ; EDX distinto de 0: no cabe
    add eax, ecx                    ; sumar el acarreo
    jc m6_ovf
    mov edx, eax                    ; parte alta final
    pop eax                         ; parte baja final
    clc
    ret
m6_ovf:
    pop eax
    stc
    ret
Mul64 ENDP

; ============================================================================
; SALIDA: conversiones propias numero -> cadena
; ============================================================================

; ----------------------------------------------------------------------------
; UInt64ToStr: entero de 64 bits -> cadena decimal. Divide entre 10; cada
;   residuo es un digito (de derecha a izquierda), se apila y luego se saca
;   para escribirlo en orden correcto. Digito + '0' = codigo ASCII.
; Entrada : EDX:EAX = valor, EDI = destino
; Salida  : cadena terminada en 00h; EDI apunta a ese 00h
; Modifica: EAX, EDX, EDI, banderas.   Conserva: EBX, ECX, ESI (USES)
; ----------------------------------------------------------------------------
UInt64ToStr PROC USES ebx ecx esi
    xor esi, esi                    ; contador de digitos
    mov ebx, 10
u6_div:
    call Div64                      ; cociente en EDX:EAX, residuo en ECX
    add cl, '0'                     ; residuo -> ASCII
    push ecx
    inc esi
    mov ecx, eax
    or ecx, edx                     ; ZF=1 cuando el cociente llego a 0
    jnz u6_div
u6_pop:
    pop ecx                         ; el ultimo digito apilado es el primero
    mov [edi], cl
    inc edi
    dec esi
    jnz u6_pop
    mov BYTE PTR [edi], 0
    ret
UInt64ToStr ENDP

; ----------------------------------------------------------------------------
; FormatAmt: centavos -> "pesos.cc". DIV entre 100 separa pesos (cociente) y
;   centavos (residuo); DIV entre 10 da AL = decenas, AH = unidades, asi un
;   residuo de 5 se muestra como "05".
; Entrada : EDX:EAX = centavos, EDI = destino
; Salida  : cadena terminada en 00h; EDI apunta a ese 00h
; Modifica: EDI, banderas.   Conserva: EAX, EBX, ECX, EDX (USES)
; ----------------------------------------------------------------------------
FormatAmt PROC USES eax ebx ecx edx
    mov ebx, 100
    call Div64                      ; EDX:EAX = pesos, ECX = centavos
    push ecx                        ; guardar centavos
    call UInt64ToStr                ; escribe los pesos
    pop eax                         ; EAX = centavos (0..99)
    mPutChar '.'
    mov bl, 10
    div bl                          ; AX / 10 -> AL = decenas, AH = unidades
    add al, '0'
    add ah, '0'                     ; siempre dos digitos: 5 -> "05"
    mov [edi], al
    mov [edi+1], ah
    add edi, 2
    mov BYTE PTR [edi], 0
    ret
FormatAmt ENDP

; ----------------------------------------------------------------------------
; FormatMXN: centavos -> "$pesos.cc MXN".
; Entrada : EDX:EAX = centavos, EDI = destino
; Salida  : cadena terminada en 00h; EDI apunta a ese 00h
; Modifica: EDI, banderas.   (FormatAmt conserva EAX, EBX, ECX, EDX)
; ----------------------------------------------------------------------------
FormatMXN PROC
    mPutChar '$'
    call FormatAmt
    mov DWORD PTR [edi], 'NXM '     ; bytes 20h 'M' 'X' 'N' = " MXN"
    mov BYTE PTR [edi+4], 0
    add edi, 4
    ret
FormatMXN ENDP

; ----------------------------------------------------------------------------
; PrintUInt: muestra EAX como decimal (sin WriteDec).
; Entrada : EAX = valor.   Modifica: banderas.   Conserva: EAX, EDX, EDI (USES)
; ----------------------------------------------------------------------------
PrintUInt PROC USES eax edx edi
    xor edx, edx
    mov edi, OFFSET numBuf
    call UInt64ToStr
    mPrint numBuf
    ret
PrintUInt ENDP

; ----------------------------------------------------------------------------
; PrintMXN: muestra EDX:EAX (centavos) como "$X.XX MXN".
; Entrada : EDX:EAX = centavos.   Modifica: banderas.
; Conserva: EAX, EDX, EDI (USES)
; ----------------------------------------------------------------------------
PrintMXN PROC USES eax edx edi
    mov edi, OFFSET numBuf
    call FormatMXN
    mPrint numBuf
    ret
PrintMXN ENDP

; ----------------------------------------------------------------------------
; ShowRecord: imprime un registro.
; Entrada : ESI = direccion del registro.   Conserva: EAX, EDX (USES)
; ----------------------------------------------------------------------------
ShowRecord PROC USES eax edx
    lea edx, [esi+OFF_CODE]
    call WriteString
    mPrint sSep
    lea edx, [esi+OFF_NAME]
    call WriteString
    mPrint sSep
    mLoad32 [esi+OFF_PRICE]         ; precio de 32 bits -> EDX:EAX
    call PrintMXN
    mPrint sSep
    mov eax, [esi+OFF_STOCK]
    call PrintUInt
    mPrint sUds
    call Crlf
    ret
ShowRecord ENDP

; ============================================================================
; CALCULO DE IMPORTES
; ============================================================================

; ----------------------------------------------------------------------------
; CalcDiscount: regla del negocio. Si la cantidad es >= DISC_MINQTY el
;   descuento es base * DISC_PCT / 100 (division entera: se descartan las
;   fracciones de centavo); en otro caso es 0.
; Entrada : EDX:EAX = importe base, ECX = cantidad
; Salida  : EDX:EAX = descuento; CF=1 si hay desbordamiento
; Modifica: EAX, EDX, banderas.   Conserva: EBX, ECX (USES)
; ----------------------------------------------------------------------------
CalcDiscount PROC USES ebx ecx
    cmp ecx, DISC_MINQTY
    jb cd_none
    mov ebx, DISC_PCT
    call Mul64                      ; EDX:EAX = base * 10
    jc cd_out
    mov ebx, 100
    call Div64                      ; EDX:EAX = base*10/100
    clc
    ret
cd_none:
    xor eax, eax
    xor edx, edx                    ; XOR deja CF=0
cd_out:
    ret
CalcDiscount ENDP

; ----------------------------------------------------------------------------
; CalcSale: calcula base, descuento e importe final de una venta SIN modificar
;           el catalogo ni los ingresos.
; Entrada : ESI = registro del producto, ECX = cantidad (ya validada)
; Salida  : baseAmt, discAmt, finalAmt (64 bits);
;           EDX:EAX = ingresos actuales + importe final (nuevo total);
;           CF=1 si hay desbordamiento
; Modifica: EAX, EDX, banderas, baseAmt/discAmt/finalAmt.
; Conserva: EBX, ECX (USES), ESI (no se toca)
; ----------------------------------------------------------------------------
CalcSale PROC USES ebx ecx
    mov eax, [esi+OFF_PRICE]
    mul ecx                         ; base = precio * cantidad (EDX:EAX)
    mStore64 baseAmt
    call CalcDiscount
    jc cs_out
    mStore64 discAmt
    mLoad64 baseAmt                 ; final = base - descuento
    sub eax, discAmt
    sbb edx, discAmt+4
    mStore64 finalAmt
    add eax, income                 ; nuevo total de ingresos
    adc edx, income+4               ; CF=1 si desborda 64 bits
cs_out:
    ret
CalcSale ENDP

; ----------------------------------------------------------------------------
; ShowSale: muestra el desglose de la ultima venta calculada.
; Modifica: EAX, EDX, banderas.
; ----------------------------------------------------------------------------
ShowSale PROC
    mPrint tSale
    mPrintAmtLine tBase, baseAmt
    mov eax, discAmt
    or eax, discAmt+4
    jz ss_nodisc                    ; descuento = 0 -> no se aplico
    mPrintAmtLine tDisc, discAmt
    jmp ss_final
ss_nodisc:
    mPrint tNoDisc
ss_final:
    mPrintAmtLine tFinal, finalAmt
    ret
ShowSale ENDP

; ----------------------------------------------------------------------------
; ComputeTotals: unidades y valor del inventario (suma precio*existencia).
; Salida  : EAX = unidades; totValue = valor en centavos (64 bits);
;           CF=1 si hay desbordamiento
; Modifica: EAX, EDX, banderas.   Conserva: ECX, ESI, EDI (USES)
; ----------------------------------------------------------------------------
ComputeTotals PROC USES ecx esi edi
    xor edi, edi                    ; unidades
    mov totValue, 0
    mov totValue+4, 0
    mov ecx, prodCount
    mov esi, OFFSET inventory
    test ecx, ecx
    jz ct_done
ct_loop:
    mov eax, [esi+OFF_STOCK]
    add edi, eax
    mul DWORD PTR [esi+OFF_PRICE]   ; EDX:EAX = existencia * precio
    add totValue, eax               ; suma de 64 bits: ADD + ADC
    adc totValue+4, edx
    jc ct_ovf
    add esi, RECSIZE
    dec ecx
    jnz ct_loop
ct_done:
    mov eax, edi
    clc
    ret
ct_ovf:
    stc
    ret
ComputeTotals ENDP

; ============================================================================
; OPCIONES DEL MENU
; ============================================================================

; ----------------------------------------------------------------------------
; DoRegister: alta de un auto. Todo se captura en newRec y solo se copia al
;             catalogo cuando TODAS las validaciones pasan.
; ----------------------------------------------------------------------------
DoRegister PROC
    cmp prodCount, MAXPROD
    jb dg_room
    mReject eFull
dg_room:
    mClearMem newRec, RECSIZE
    call AskCode                    ; codigo (formato) en inBuf
    jc dg_out
    mov edx, OFFSET inBuf
    call FindByCode
    jnc dg_dup                      ; CF=0 -> ya existe
    mCopyMem newRec+OFF_CODE, inBuf, 8      ; 7 caracteres + 00h
    call AskName                    ; EAX = longitud
    jc dg_out
    mCopyMem newRec+OFF_NAME, inBuf, eax
    call AskPrice
    jc dg_out
    mov DWORD PTR [newRec+OFF_PRICE], eax
    call AskStock
    jc dg_out
    mov DWORD PTR [newRec+OFF_STOCK], eax

    mov eax, prodCount              ; ---- confirmar: copiar al catalogo
    imul eax, RECSIZE
    mov edi, OFFSET inventory
    add edi, eax                    ; EDI = siguiente registro libre
    mov esi, OFFSET newRec
    mov ecx, RECSIZE
    rep movsb
    inc prodCount
    mov dirty, 1
    mPrint okReg
dg_out:
    ret
dg_dup:
    mReject eDup
DoRegister ENDP

; ----------------------------------------------------------------------------
; DoList: muestra todo el inventario (recorrido con ESI).
; Conserva: ECX, ESI (USES)
; ----------------------------------------------------------------------------
DoList PROC USES ecx esi
    mRequireProducts
    mPrint tHeader
    mov ecx, prodCount
    mov esi, OFFSET inventory
dl_loop:
    call ShowRecord
    add esi, RECSIZE
    dec ecx
    jnz dl_loop
    ret
DoList ENDP

; ----------------------------------------------------------------------------
; DoSearch: busca por codigo y muestra el registro.
; ----------------------------------------------------------------------------
DoSearch PROC
    mRequireProducts
    call AskCodeFind
    jc ds_out
    mPrint tHeader
    call ShowRecord
ds_out:
    ret
DoSearch ENDP

; ----------------------------------------------------------------------------
; DoReceive: suma unidades a un producto existente sin pasar de 100.
; ----------------------------------------------------------------------------
DoReceive PROC
    mRequireProducts
    call AskCodeFind
    jc dr_out
    mov selRec, esi                 ; recordar el registro
    call ShowRecord
    mov edx, OFFSET pRecv
    call AskQty
    jc dr_out
    mov esi, selRec
    mov ebx, [esi+OFF_STOCK]
    add ebx, eax
    jc dr_exceed                    ; desbordamiento de 32 bits
    cmp ebx, MAXSTOCK
    ja dr_exceed                    ; supera 100 unidades
    mov [esi+OFF_STOCK], ebx        ; solo aqui se modifica el catalogo
    mov dirty, 1
    mPrint okRecv
    mov eax, ebx
    call PrintUInt
    call Crlf
dr_out:
    ret
dr_exceed:
    mReject eExceed
DoReceive ENDP

; ----------------------------------------------------------------------------
; DoSell: venta de un solo producto con la regla de descuento por cantidad.
;   CalcSale calcula todo sin tocar datos; solo si no hay rechazo se
;   actualizan ingresos y existencia (sin cambios parciales).
; ----------------------------------------------------------------------------
DoSell PROC
    mRequireProducts
    call AskCodeFind
    jc dv_out
    mov selRec, esi
    call ShowRecord
    mov edx, OFFSET pQty
    call AskQty                     ; EAX = cantidad
    jc dv_out
    mov esi, selRec
    cmp eax, [esi+OFF_STOCK]
    ja dv_nostock                   ; cantidad > existencia
    mov ecx, eax                    ; ECX = cantidad
    call CalcSale                   ; EDX:EAX = nuevos ingresos
    jc dv_ovf
    mStore64 income                 ; ---- confirmar la venta
    sub [esi+OFF_STOCK], ecx
    mov dirty, 1
    call ShowSale
dv_out:
    ret
dv_nostock:
    mReject eNoStock
dv_ovf:
    mReject eOvf
DoSell ENDP

; ----------------------------------------------------------------------------
; DoSummary: unidades, valor del inventario e ingresos de la sesion.
; ----------------------------------------------------------------------------
DoSummary PROC
    call ComputeTotals
    jc su_ovf
    push eax                        ; guardar unidades
    mPrint tUnits
    pop eax
    call PrintUInt
    call Crlf
    mPrintAmtLine tValue, totValue
    mPrintAmtLine tIncome, income
    ret
su_ovf:
    mReject eOvf
DoSummary ENDP

; ----------------------------------------------------------------------------
; DoLoad: opcion 8. Pide confirmacion si hay cambios sin guardar.
; ----------------------------------------------------------------------------
DoLoad PROC
    cmp dirty, 0
    je dd_go
    mov edx, OFFSET pLoadAsk
    call AskYesNo
    test eax, eax
    jz dd_out                       ; el usuario cancelo
dd_go:
    call LoadCatalog
dd_out:
    ret
DoLoad ENDP

; ----------------------------------------------------------------------------
; ConfirmExit: avisa si hay cambios sin guardar al salir.
; Salida  : EAX = 1 si se debe salir, 0 si se cancela
; Modifica: EAX, EDX, banderas.
; ----------------------------------------------------------------------------
ConfirmExit PROC
    cmp dirty, 0
    je ce_yes
    mPrompt pExit
    cmp eax, 1
    jne ce_no                       ; cancelar
    mov al, [inBuf]
    mToLower al
    cmp al, 's'
    je ce_save
    cmp al, 'n'
    je ce_yes
ce_no:
    xor eax, eax
    ret
ce_save:
    call SaveCatalog
    cmp dirty, 0
    jne ce_no                       ; si fallo el guardado no se sale
ce_yes:
    mov eax, 1
    ret
ConfirmExit ENDP

; ============================================================================
; ARCHIVO DE TEXTO
; ============================================================================

; ----------------------------------------------------------------------------
; AppendStr: copia una cadena (sin el 00h) al destino.
; Entrada : ESI = origen (terminado en 00h), EDI = destino
; Salida  : EDI apunta justo despues del ultimo caracter copiado
; Modifica: ESI, EDI, banderas.   Conserva: EAX (USES)
; ----------------------------------------------------------------------------
AppendStr PROC USES eax
as_loop:
    mov al, [esi]
    test al, al
    jz as_done
    mov [edi], al
    inc esi
    inc edi
    jmp as_loop
as_done:
    ret
AppendStr ENDP

; ----------------------------------------------------------------------------
; BuildText: genera en fileBuf el texto del catalogo, una linea por producto:
;            CODIGO;NOMBRE;PRECIO;EXISTENCIA CR LF
; Salida  : fileBuf con el texto; bytesReq = longitud en bytes
; Modifica: EAX, EDX, banderas, bytesReq.   Conserva: EBX, ECX, ESI, EDI (USES)
; ----------------------------------------------------------------------------
BuildText PROC USES ebx ecx esi edi
    mov edi, OFFSET fileBuf
    mov ebx, OFFSET inventory       ; EBX = registro actual
    mov ecx, prodCount
    test ecx, ecx
    jz bt_end
bt_rec:
    lea esi, [ebx+OFF_CODE]
    call AppendStr
    mPutChar SEP
    lea esi, [ebx+OFF_NAME]
    call AppendStr
    mPutChar SEP
    mLoad32 [ebx+OFF_PRICE]
    call FormatAmt                  ; "3500000.00"; EDI -> su 00h
    mPutChar SEP                    ; el 00h se sobrescribe con ';'
    mLoad32 [ebx+OFF_STOCK]
    call UInt64ToStr                ; existencia; EDI -> su 00h
    mPutChar 0Dh                    ; CR (sobrescribe el 00h)
    mPutChar 0Ah                    ; LF
    add ebx, RECSIZE
    dec ecx
    jnz bt_rec
bt_end:
    sub edi, OFFSET fileBuf         ; longitud total
    mov bytesReq, edi
    ret
BuildText ENDP

; ----------------------------------------------------------------------------
; SaveCatalog: escribe el texto en inventario.txt. Verifica el handle y que
;              EAX (bytes escritos) sea igual a los bytes solicitados.
; Efecto  : dirty = 0 solo si todo salio bien.
; ----------------------------------------------------------------------------
SaveCatalog PROC
    call BuildText
    mov edx, OFFSET fileName
    call CreateOutputFile           ; EAX = handle
    cmp eax, BAD_HANDLE
    je sv_errcreate
    mov hFile, eax
    mov edx, OFFSET fileBuf
    mov ecx, bytesReq
    call WriteToFile                ; EAX = bytes escritos
    mov bytesDone, eax
    mov eax, hFile
    call CloseFile
    mov eax, bytesDone
    cmp eax, bytesReq
    jne sv_errwrite
    mov dirty, 0
    mPrint okSave
    ret
sv_errcreate:
    mReject eCreate
sv_errwrite:
    mReject eWrite
SaveCatalog ENDP

; ----------------------------------------------------------------------------
; GetField: copia a fldBuf los caracteres desde txtPtr hasta ';', CR, LF o 00h.
; Entrada : txtPtr = posicion en el texto
; Salida  : fldBuf terminado en 00h; AL = caracter que termino el campo
;           (no se consume); txtPtr apunta a ese caracter;
;           CF=1 si el campo excede MAXIN caracteres
; Modifica: EAX, txtPtr, banderas.   Conserva: ECX, EDX, ESI (USES)
; ----------------------------------------------------------------------------
GetField PROC USES ecx edx esi
    mov esi, txtPtr
    mov edx, OFFSET fldBuf
    xor ecx, ecx
gf_loop:
    mov al, [esi]
    cmp al, SEP
    je gf_end
    cmp al, 0Dh
    je gf_end
    cmp al, 0Ah
    je gf_end
    test al, al
    jz gf_end
    cmp ecx, MAXIN
    jae gf_bad
    mov [edx], al
    inc edx
    inc ecx
    inc esi
    jmp gf_loop
gf_end:
    mov BYTE PTR [edx], 0
    mov txtPtr, esi
    clc
    ret
gf_bad:
    stc
    ret
GetField ENDP

; ----------------------------------------------------------------------------
; NextField: lee un campo que debe terminar en ';' y avanza txtPtr despues de el.
; Salida  : fldBuf con el campo; CF=1 si es muy largo o no termina en ';'
; Modifica: EAX, txtPtr, banderas.
; ----------------------------------------------------------------------------
NextField PROC
    call GetField
    jc nf_out
    cmp al, SEP
    jne nf_bad
    inc txtPtr                      ; saltar el ';'
    clc
nf_out:
    ret
nf_bad:
    stc
    ret
NextField ENDP

; ----------------------------------------------------------------------------
; LastField: lee el ultimo campo de la linea (NO debe terminar en ';').
; Salida  : fldBuf con el campo; CF=1 si es muy largo o hay un ';' de mas
; Modifica: EAX, txtPtr, banderas.
; ----------------------------------------------------------------------------
LastField PROC
    call GetField
    jc lf_out
    cmp al, SEP
    je lf_bad                       ; campo de mas
    clc
lf_out:
    ret
lf_bad:
    stc
    ret
LastField ENDP

; ----------------------------------------------------------------------------
; ParseFile: interpreta el texto de fileBuf (terminado en 00h) y construye el
;   catalogo TEMPORAL tmpInv/tmpCount. Cada linea se valida con los mismos
;   procedimientos de la captura; ademas: maximo 10 productos, codigos no
;   repetidos y que no haya 00h intermedios.
; Entrada : fileBuf (con 00h al final), bytesDone = bytes leidos
; Salida  : CF=1 si el archivo es invalido (el catalogo real no se toca)
; Modifica: EAX, banderas, tmpInv, tmpCount, txtPtr.
; Conserva: EBX, ECX, EDX, ESI, EDI (USES)
; ----------------------------------------------------------------------------
ParseFile PROC USES ebx ecx edx esi edi
    mClearMem tmpInv, MAXPROD*RECSIZE
    mov tmpCount, 0
    mov txtPtr, OFFSET fileBuf
pf_line:
    mov esi, txtPtr
    mov al, [esi]
    test al, al
    jz pf_end                       ; fin del texto
    cmp al, 0Dh
    je pf_skip                      ; saltar CR / LF / lineas vacias
    cmp al, 0Ah
    je pf_skip
    cmp tmpCount, MAXPROD
    jae pf_bad                      ; mas de 10 productos
    mov eax, tmpCount
    imul eax, eax, RECSIZE
    lea ebx, [tmpInv+eax]           ; EBX = registro destino

    call NextField                  ; ---- campo 1: codigo
    jc pf_bad
    mCallOn fldBuf, ValidateCode
    jc pf_bad
    mov edi, ebx
    mov ecx, 8
    rep movsb                       ; 7 caracteres + 00h

    call NextField                  ; ---- campo 2: nombre
    jc pf_bad
    mCallOn fldBuf, ValidateName
    jc pf_bad
    mov ecx, eax                    ; EAX = longitud
    lea edi, [ebx+OFF_NAME]
    rep movsb

    call NextField                  ; ---- campo 3: precio
    jc pf_bad
    mCallOn fldBuf, ParsePrice
    jc pf_bad
    mov [ebx+OFF_PRICE], eax

    call LastField                  ; ---- campo 4: existencia
    jc pf_bad
    mCallOn fldBuf, ParseUInt
    jc pf_bad
    cmp eax, MAXSTOCK
    ja pf_bad
    mov [ebx+OFF_STOCK], eax

    mov edx, ebx                    ; ---- codigo repetido?
    mov esi, OFFSET tmpInv          ; buscar entre los registros previos
    mov ecx, tmpCount
    call FindCodeIn
    jnc pf_bad                      ; CF=0 -> ya estaba
    inc tmpCount
    jmp pf_line
pf_skip:
    inc txtPtr
    jmp pf_line
pf_end:
    mov eax, esi                    ; el 00h debe estar en el ultimo byte leido
    sub eax, OFFSET fileBuf
    cmp eax, bytesDone
    jne pf_bad                      ; hay un 00h intermedio
    clc
    ret
pf_bad:
    stc
    ret
ParseFile ENDP

; ----------------------------------------------------------------------------
; ReadTextFile: abre, lee y cierra inventario.txt en fileBuf. Pide
;   FILEBUFSIZE-1 bytes: la capacidad del buffer (1024) es mayor que los
;   bytes leidos y el ultimo byte queda reservado para el 00h final que se
;   agrega en fileBuf[bytes leidos] para tratar el texto como cadena.
; Salida  : CF=0: fileBuf con 00h al final y bytesDone = bytes leidos;
;           CF=1: error (el mensaje ya se mostro)
; Modifica: EAX, ECX, EDX, banderas, hFile, bytesDone.
; ----------------------------------------------------------------------------
ReadTextFile PROC
    mov edx, OFFSET fileName
    call OpenInputFile              ; EAX = handle
    cmp eax, BAD_HANDLE
    je rt_nofile
    mov hFile, eax
    mov edx, OFFSET fileBuf
    mov ecx, FILEBUFSIZE-1          ; capacidad menos 1 byte para el 00h
    call ReadFromFile               ; EAX = bytes leidos; CF=1 si error
    jc rt_readerr
    mov bytesDone, eax
    mov eax, hFile
    call CloseFile
    mov eax, bytesDone
    cmp eax, FILEBUFSIZE-1
    jae rt_big                      ; el archivo no cabe: demasiado grande
    mov BYTE PTR [fileBuf+eax], 0   ; 00h despues del ultimo byte leido
    clc
    ret
rt_nofile:
    mFail eNoFile
rt_readerr:
    mov eax, hFile
    call CloseFile
    mFail eRead
rt_big:
    mFail eBadFile
ReadTextFile ENDP

; ----------------------------------------------------------------------------
; LoadCatalog: lee el archivo, lo interpreta en el catalogo temporal y SOLO si
;              es correcto reemplaza el catalogo real. Si falta o esta
;              danado se conserva el catalogo actual.
; ----------------------------------------------------------------------------
LoadCatalog PROC
    call ReadTextFile
    jc lc_out                       ; error ya reportado
    call ParseFile
    jc lc_bad
    mCopyMem inventory, tmpInv, MAXPROD*RECSIZE    ; datos validos: reemplazar
    mov eax, tmpCount
    mov prodCount, eax
    mov dirty, 0
    mPrint okLoad
    mov eax, prodCount
    call PrintUInt
    call Crlf
lc_out:
    ret
lc_bad:
    mReject eBadFile
LoadCatalog ENDP

END main