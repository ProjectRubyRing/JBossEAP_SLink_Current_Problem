# 検証用 WAR (ticker.war) を作る。
#   /ticker/log.jsp?who=XXX  … server.log に "TICK who=XXX" を 1 行出す (任意のタイミングでログを出すため)。
#                              リクエスト自体は Undertow の access_log.log にも 1 行残る。
#   /ticker/gc.jsp?op=gc     … System.gc() を数回呼び、gc.log に行を出す
#   /ticker/gc.jsp?op=rotate … JVM の GC ログを今すぐローテーションさせる
#                              (jcmd <pid> VM.log rotate と同じ。JRE だけでも動くよう MBean 経由)。
#                              ローテーションの処理は容量 (filesize) に達したときと同じ関数で行われる。
import zipfile

LOG_JSP = '''<%@ page contentType="text/plain; charset=UTF-8" %><%
  String who = request.getParameter("who");
  java.util.logging.Logger.getLogger("ticker").info("TICK who=" + who);
  out.print("ok " + who);
%>'''

GC_JSP = '''<%@ page contentType="text/plain; charset=UTF-8" %><%
  String op = request.getParameter("op");
  String r;
  if ("rotate".equals(op)) {
    javax.management.MBeanServer mbs = java.lang.management.ManagementFactory.getPlatformMBeanServer();
    javax.management.ObjectName dc = new javax.management.ObjectName("com.sun.management:type=DiagnosticCommand");
    Object res = mbs.invoke(dc, "vmLog", new Object[] { new String[] { "rotate" } },
                            new String[] { String[].class.getName() });
    r = "rotated" + (res == null || res.toString().trim().isEmpty() ? "" : " " + res.toString().trim());
  } else {
    for (int i = 0; i < 3; i++) { System.gc(); }
    r = "gc x3";
  }
  out.print("ok " + op + " " + r);
%>'''

with zipfile.ZipFile("ticker.war", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("log.jsp", LOG_JSP)
    z.writestr("gc.jsp", GC_JSP)
print("ticker.war created")
