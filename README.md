# Sistema de Ventas e Inventario - Concesionaria de Autos (Unidad 3)

Proyecto desarrollado en **MASM x86 (32 bits)** utilizando la librería **Irvine32**, aplicando procedimientos, macros, `USES` y una regla de negocio (descuento por cantidad).

## Contenido del Repositorio
- [`Proyecto_u3/U3Consesionaria.asm`](Proyecto_u3/U3Consesionaria.asm): Código fuente principal refactorizado con macros, procedimientos y `USES`.
- [`Proyecto_u3/inventario.txt`](Proyecto_u3/inventario.txt): Archivo de texto plano con el inventario inicial para pruebas.
- [`Proyecto_u3/Li_Proyecto_U2(Actualizado).pdf`](Proyecto_u3/Li_Proyecto_U2(Actualizado).pdf): Documento con el reporte actualizado de la Unidad 3.

## Instrucciones de Compilación y Ejecución (Visual Studio)

1. **Requisitos previos:**
   - Tener instalado **Visual Studio** con el soporte para C++ / MASM configurado.
   - Tener instalada la librería **Irvine32** (archivos `Irvine32.inc`, `Irvine32.lib` y `SmallWin.inc` configurados en tu entorno).

2. **Pasos para ejecutar:**
   - Abre Visual Studio y crea un nuevo proyecto vacio de C++ (o abre tu proyecto existente).
   - Agrega el archivo `U3Consesionaria.asm` al proyecto.
   - Asegúrate de configurar las propiedades del proyecto para habilitar ensamblado en 32 bits y enlazar con `Irvine32.lib`.
   - Coloca el archivo `inventario.txt` en la carpeta raíz donde se genera el ejecutable (`.exe`) para que el programa pueda leerlo y modificarlo correctamente.
   - Compila y ejecuta (`Ctrl + F5`).