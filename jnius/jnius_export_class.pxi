
class JavaException(Exception):
    '''Can be a real java exception, or just an exception from the wrapper.
    '''
    pass


cdef class JavaObject(object):
    '''Can contain any Java object. Used to store instance, or whatever.
    '''

    cdef jobject obj

    def __cinit__(self):
        self.obj = NULL


cdef class JavaClassStorage:
    # dangerous to store JNIEnv in threaded scenario
    # will work for instantiating thread but fail if another thread tries to use it
    # can j_env be stored in thread-local?
    cdef JNIEnv *j_env
    cdef jclass j_cls

    def __cinit__(self):
        self.j_env = NULL
        self.j_cls = NULL


cdef dict jclass_register = {}

class MetaJavaClass(type):
    def __new__(meta, classname, bases, classDict):
        meta.resolve_class(classDict)
        tp = type.__new__(meta, classname, bases, classDict)
        jclass_register[classDict['__javaclass__']] = tp
        return tp

    @staticmethod
    def get_javaclass(name):
        return jclass_register.get(name)

    @classmethod
    def resolve_class(meta, classDict):
        # search the Java class, and bind to our object
        if not '__javaclass__' in classDict:
            raise JavaException('__javaclass__ definition missing')

        cdef JavaClassStorage jcs = JavaClassStorage()
        cdef bytes __javaclass__ = <bytes>classDict['__javaclass__']
        cdef bytes __javainterfaces__ = <bytes>classDict.get('__javainterfaces__', '')
        cdef bytes __javabaseclass__ = <bytes>classDict.get('__javabaseclass__', '')
        cdef jmethodID getProxyClass, getClassLoader
        cdef jclass *interfaces
        cdef jobject *jargs

        # dangerous to store JNIEnv in threaded scenario
        # will work for instantiating thread but fail if another thread tries to use it
        # can j_env be stored in thread-local?
        jcs.j_env = get_jnienv()
        if jcs.j_env == NULL:
            raise JavaException('Unable to get the JNI Environment')

        if __javainterfaces__ and __javabaseclass__:
            baseclass = jcs.j_env[0].FindClass(jcs.j_env, <char*>__javabaseclass__)
            interfaces = <jclass *>malloc(sizeof(jclass) * len(__javainterfaces__))

            for n, i in enumerate(__javainterfaces__):
                interfaces[n] = jcs.j_env[0].FindClass(jcs.j_env, <char*>i)

            getProxyClass = jcs.j_env[0].GetStaticMethodID(
                jcs.j_env, baseclass, "getProxyClass",
                "(Ljava/lang/ClassLoader,[Ljava/lang/Class;)Ljava/lang/Class;")

            getClassLoader = jcs.j_env[0].GetStaticMethodID(
                jcs.j_env, baseclass, "getClassLoader", "()Ljava/lang/Class;")

            classLoader = jcs.j_env[0].CallStaticObjectMethodA(
                    jcs.j_env, baseclass, getClassLoader, [])

            jargs = <jobject*>malloc(sizeof(jobject) * 2)
            jargs[0] = classLoader
            jargs[1] = interfaces
            jcs.j_cls = jcs.j_env[0].CallStaticObjectMethod(
                    jcs.j_env, baseclass, getProxyClass, jargs)

            if jcs.j_cls == NULL:
                raise JavaException('Unable to create the class'
                        ' {0}'.format(__javaclass__))
        else:
            jcs.j_cls = jcs.j_env[0].FindClass(jcs.j_env,
                    <char *>__javaclass__)
            if jcs.j_cls == NULL:
                raise JavaException('Unable to find the class'
                        ' {0}'.format(__javaclass__))

        classDict['__cls_storage'] = jcs

        # search all the static JavaMethod within our class, and resolve them
        cdef JavaMethod jm
        cdef JavaMultipleMethod jmm
        cdef PythonMethod pm
        for name, value in classDict.iteritems():
            if isinstance(value, JavaMethod):
                jm = value
                if not jm.is_static:
                    continue
                jm.set_resolve_info(jcs.j_env, jcs.j_cls, None,
                    name, __javaclass__)
            elif isinstance(value, JavaMultipleMethod):
                jmm = value
                jmm.set_resolve_info(jcs.j_env, jcs.j_cls, None,
                    name, __javaclass__)
            elif isinstance(value, PythonMethod):
                if '__javabaseclass__' not in classDict:
                    raise JavaException("Can't use PythonMethod on a java "
                    "class, you must use inheritance to implement a java "
                    "interface")
                pm = value
                pm.set_resolve_info(jcs.j_env, jcs.j_cls, jcs.j_self,
                    name, jcs.__javaclass__)


        # search all the static JavaField within our class, and resolve them
        cdef JavaField jf
        for name, value in classDict.iteritems():
            if not isinstance(value, JavaField):
                continue
            jf = value
            if not jf.is_static:
                continue
            jf.set_resolve_info(jcs.j_env, jcs.j_cls, None,
                name, __javaclass__)


cdef class JavaClass(object):
    '''Main class to do introspection.
    '''

    # dangerous to store JNIEnv in threaded scenario
    # will work for instantiating thread but fail if another thread tries to use it
    # can j_env be stored in thread-local?
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef LocalRef j_self

    def __cinit__(self, *args, **kwargs):
        self.j_env = NULL
        self.j_cls = NULL
        self.j_self = None

    def __init__(self, *args, **kwargs):
        super(JavaClass, self).__init__()
        # copy the current attribute in the storage to our class
        cdef JavaClassStorage jcs = self.__cls_storage
        self.j_env = jcs.j_env
        self.j_cls = jcs.j_cls

        if 'noinstance' not in kwargs:
            self.call_constructor(args)
            self.resolve_methods()
            self.resolve_fields()

    cdef void instanciate_from(self, LocalRef j_self) except *:
        self.j_self = j_self
        self.resolve_methods()
        self.resolve_fields()

    cdef void call_constructor(self, args) except *:
        # the goal is to find the class constructor, and call it with the
        # correct arguments.
        cdef jvalue *j_args = NULL
        cdef jobject j_self = NULL
        cdef jmethodID constructor = NULL

        # get the constructor definition if exist
        definitions = [('()V', False)]
        if hasattr(self, '__javaconstructor__'):
            definitions = self.__javaconstructor__
        if isinstance(definitions, basestring):
            definitions = [definitions]

        if len(definitions) == 0:
            raise JavaException('No constructor available')

        elif len(definitions) == 1:
            definition, is_varargs = definitions[0]
            d_ret, d_args = parse_definition(definition)

            if is_varargs:
                args_ = args[:len(d_args) - 1] + (args[len(d_args) - 1:],)
            else:
                args_ = args
            if len(args or ()) != len(d_args or ()):
                raise JavaException('Invalid call, number of argument'
                        ' mismatch for constructor')
        else:
            scores = []
            for definition, is_varargs in definitions:
                d_ret, d_args = parse_definition(definition)
                if is_varargs:
                    args_ = args[:len(d_args) - 1] + (args[len(d_args) - 1:],)
                else:
                    args_ = args

                score = calculate_score(d_args, args)
                if score == -1:
                    continue
                scores.append((score, definition, d_ret, d_args, args_))
            if not scores:
                raise JavaException('No constructor matching your arguments')
            scores.sort()
            score, definition, d_ret, d_args, args_ = scores[-1]

        try:
            # convert python arguments to java arguments
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                populate_args(self.j_env, d_args, j_args, args_)

            # get the java constructor
            constructor = self.j_env[0].GetMethodID(
                self.j_env, self.j_cls, '<init>', <char *><bytes>definition)
            if constructor == NULL:
                raise JavaException('Unable to found the constructor'
                        ' for {0}'.format(self.__javaclass__))

            # create the object
            j_self = self.j_env[0].NewObjectA(self.j_env, self.j_cls,
                    constructor, j_args)
            if j_self == NULL:
                raise JavaException('Unable to instanciate {0}'.format(
                    self.__javaclass__))

            self.j_self = create_local_ref(self.j_env, j_self)
        finally:
            if j_args != NULL:
                free(j_args)

    cdef void resolve_methods(self) except *:
        # search all the JavaMethod within our class, and resolve them
        cdef JavaMethod jm
        cdef JavaMultipleMethod jmm
        cdef PythonMethod pm
        # dangerous to store JNIEnv in threaded scenario
        # will work for instantiating thread but fail if another thread tries to use it
        # can j_env be stored in thread-local?
        for name, value in self.__class__.__dict__.iteritems():
            if isinstance(value, JavaMethod):
                jm = value
                if jm.is_static:
                    continue
                jm.set_resolve_info(self.j_env, self.j_cls, self.j_self,
                    name, self.__javaclass__)
            elif isinstance(value, JavaMultipleMethod):
                jmm = value
                jmm.set_resolve_info(self.j_env, self.j_cls, self.j_self,
                    name, self.__javaclass__)
            elif isinstance(value, PythonMethod):
                pm = value
                pm.set_resolve_info(self.j_env, self.j_cls, self.j_self,
                    name, self.__javaclass__)

    cdef void resolve_fields(self) except *:
        # search all the JavaField within our class, and resolve them
        cdef JavaField jf
        for name, value in self.__class__.__dict__.iteritems():
            if not isinstance(value, JavaField):
                continue
            jf = value
            if jf.is_static:
                continue
            # dangerous to store JNIEnv in threaded scenario
            # will work for instantiating thread but fail if another thread tries to use it
            # can j_env be stored in thread-local?
            jf.set_resolve_info(self.j_env, self.j_cls, self.j_self,
                name, self.__javaclass__)

    def __repr__(self):
        return '<{0} at 0x{1:x} jclass={2} jself={3}>'.format(
                self.__class__.__name__,
                id(self),
                self.__javaclass__,
                self.j_self)


cdef class JavaField(object):
    cdef jfieldID j_field
    # dangerous to store JNIEnv in threaded scenario
    # will work for instantiating thread but fail if another thread tries to use it
    # can j_env be stored in thread-local?
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef LocalRef j_self
    cdef bytes definition
    cdef object is_static
    cdef bytes name
    cdef bytes classname

    def __cinit__(self, definition, **kwargs):
        self.j_field = NULL
        self.j_env = NULL
        self.j_cls = NULL
        self.j_self = None

    def __init__(self, definition, **kwargs):
        super(JavaField, self).__init__()
        self.definition = definition
        self.is_static = kwargs.get('static', False)

    cdef void set_resolve_info(self, JNIEnv *j_env, jclass j_cls, LocalRef j_self,
            bytes name, bytes classname):
        self.name = name
        self.classname = classname
        self.j_env = j_env
        self.j_cls = j_cls
        self.j_self = j_self

    cdef void ensure_field(self) except *:
        if self.j_field != NULL:
            return
        if self.is_static:
            self.j_field = self.j_env[0].GetStaticFieldID(
                    self.j_env, self.j_cls, <char *>self.name,
                    <char *>self.definition)
        else:
            self.j_field = self.j_env[0].GetFieldID(
                    self.j_env, self.j_cls, <char *>self.name,
                    <char *>self.definition)
        if self.j_field == NULL:
            raise JavaException('Unable to found the field {0}'.format(self.name))

    def __get__(self, obj, objtype):
        self.ensure_field()
        if obj is None:
            return self.read_static_field()
        return self.read_field()

    cdef read_field(self):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject
        cdef JavaClass ret_jc
        cdef jobject j_self = self.j_self.obj

        # return type of the java method
        r = self.definition[0]

        # now call the java method
        if r == 'Z':
            j_boolean = self.j_env[0].GetBooleanField(
                    self.j_env, j_self, self.j_field)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].GetByteField(
                    self.j_env, j_self, self.j_field)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].GetCharField(
                    self.j_env, j_self, self.j_field)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].GetShortField(
                    self.j_env, j_self, self.j_field)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].GetIntField(
                    self.j_env, j_self, self.j_field)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].GetLongField(
                    self.j_env, j_self, self.j_field)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].GetFloatField(
                    self.j_env, j_self, self.j_field)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].GetDoubleField(
                    self.j_env, j_self, self.j_field)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].GetObjectField(
                    self.j_env, j_self, self.j_field)
            if j_object != NULL:
                ret = convert_jobject_to_python(
                        self.j_env, self.definition, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        elif r == '[':
            r = self.definition[1:]
            j_object = self.j_env[0].GetObjectField(
                    self.j_env, j_self, self.j_field)
            if j_object != NULL:
                ret = convert_jarray_to_python(self.j_env, r, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        else:
            raise Exception('Invalid field definition')

        check_exception(self.j_env)
        return ret

    cdef read_static_field(self):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef object ret = None

        # return type of the java method
        r = self.definition[0]

        # now call the java method
        if r == 'Z':
            j_boolean = self.j_env[0].GetStaticBooleanField(
                    self.j_env, self.j_cls, self.j_field)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].GetStaticByteField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].GetStaticCharField(
                    self.j_env, self.j_cls, self.j_field)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].GetStaticShortField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].GetStaticIntField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].GetStaticLongField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].GetStaticFloatField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].GetStaticDoubleField(
                    self.j_env, self.j_cls, self.j_field)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].GetStaticObjectField(
                    self.j_env, self.j_cls, self.j_field)
            if j_object != NULL:
                ret = convert_jobject_to_python(
                        self.j_env, self.definition, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        elif r == '[':
            r = self.definition[1:]
            j_object = self.j_env[0].GetStaticObjectField(
                    self.j_env, self.j_cls, self.j_field)
            if j_object != NULL:
                ret = convert_jarray_to_python(self.j_env, r, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        else:
            raise Exception('Invalid field definition')

        check_exception(self.j_env)
        return ret


cdef class PythonMethod(object):
    '''Used to register python method in the java class, so java can call it
    '''
    cdef bytes definition
    cdef bint is_static
    cdef bint is_varargs
    cdef bytes name
    cdef bytes classname
    # XXX

    cdef void set_resolve_info(self, JNIEnv *j_env, jclass j_cls, LocalRef j_self,
            bytes name, bytes classname):
        '''
        XXX TODO
        self.name = name
        self.classname = classname
        self.j_env = j_env
        self.j_cls = j_cls
        self.j_self = j_self
        '''
        pass


cdef class JavaMethod(object):
    '''Used to resolve a Java method, and do the call
    '''
    cdef jmethodID j_method
    cdef JNIEnv *j_env
    cdef jclass j_cls
    cdef LocalRef j_self
    cdef bytes name
    cdef bytes classname
    cdef bytes definition
    cdef object is_static
    cdef bint is_varargs
    cdef object definition_return
    cdef object definition_args

    def __cinit__(self, definition, **kwargs):
        self.j_method = NULL
        self.j_env = NULL
        self.j_cls = NULL
        self.j_self = None

    def __init__(self, definition, **kwargs):
        super(JavaMethod, self).__init__()
        self.definition = <bytes>definition
        self.definition_return, self.definition_args = \
                parse_definition(definition)
        self.is_static = kwargs.get('static', False)
        self.is_varargs = kwargs.get('varargs', False)

    cdef void ensure_method(self) except *:
        if self.j_method != NULL:
            return
        if self.is_static:
            self.j_method = self.j_env[0].GetStaticMethodID(
                    self.j_env, self.j_cls, <char *>self.name,
                    <char *>self.definition)
        else:
            self.j_method = self.j_env[0].GetMethodID(
                    self.j_env, self.j_cls, <char *>self.name,
                    <char *>self.definition)

        if self.j_method == NULL:
            raise JavaException('Unable to find the method'
                    ' {0}({1})'.format(self.name, self.definition))

    cdef void set_resolve_info(self, JNIEnv *j_env, jclass j_cls,
            LocalRef j_self, bytes name, bytes classname):
        self.name = name
        self.classname = classname
        self.j_env = j_env
        self.j_cls = j_cls
        self.j_self = j_self

    def __get__(self, obj, objtype):
        if obj is None:
            return self
        # XXX FIXME we MUST not change our own j_self, but return a "bound"
        # method here, as python does!
        cdef JavaClass jc = obj
        self.j_self = jc.j_self
        return self

    def __call__(self, *args):
        # argument array to pass to the method
        cdef jvalue *j_args = NULL
        cdef tuple d_args = self.definition_args
        if self.is_varargs:
            args = args[:len(d_args) - 1] + (args[len(d_args) - 1:],)

        if len(args) != len(d_args):
            raise JavaException('Invalid call, number of argument mismatch')

        if not self.is_static and self.j_env == NULL:
            raise JavaException('Cannot call instance method on a un-instanciated class')

        self.ensure_method()

        try:
            # convert python argument if necessary
            if len(args):
                j_args = <jvalue *>malloc(sizeof(jvalue) * len(d_args))
                if j_args == NULL:
                    raise MemoryError('Unable to allocate memory for java args')
                populate_args(self.j_env, self.definition_args, j_args, args)

            try:
                # do the call
                if self.is_static:
                    return self.call_staticmethod(j_args)
                return self.call_method(j_args)
            finally:
                release_args(self.j_env, self.definition_args, j_args, args)

        finally:
            if j_args != NULL:
                free(j_args)

    cdef call_method(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject
        cdef JavaClass ret_jc
        cdef jobject j_self = self.j_self.obj

        # return type of the java method
        r = self.definition_return[0]

        # now call the java method
        if r == 'V':
            self.j_env[0].CallVoidMethodA(
                    self.j_env, j_self, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallBooleanMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallByteMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallCharMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].CallShortMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallIntMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallLongMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallFloatMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallDoubleMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].CallObjectMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            if j_object != NULL:
                ret = convert_jobject_to_python(
                        self.j_env, self.definition_return, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        elif r == '[':
            r = self.definition_return[1:]
            j_object = self.j_env[0].CallObjectMethodA(
                    self.j_env, j_self, self.j_method, j_args)
            if j_object != NULL:
                ret = convert_jarray_to_python(self.j_env, r, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        else:
            raise Exception('Invalid return definition?')

        check_exception(self.j_env)
        return ret

    cdef call_staticmethod(self, jvalue *j_args):
        cdef jboolean j_boolean
        cdef jbyte j_byte
        cdef jchar j_char
        cdef jshort j_short
        cdef jint j_int
        cdef jlong j_long
        cdef jfloat j_float
        cdef jdouble j_double
        cdef jobject j_object
        cdef char *c_str
        cdef bytes py_str
        cdef object ret = None
        cdef JavaObject ret_jobject
        cdef JavaClass ret_jc

        # return type of the java method
        r = self.definition_return[0]

        # now call the java method
        if r == 'V':
            self.j_env[0].CallStaticVoidMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
        elif r == 'Z':
            j_boolean = self.j_env[0].CallStaticBooleanMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = True if j_boolean else False
        elif r == 'B':
            j_byte = self.j_env[0].CallStaticByteMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <char>j_byte
        elif r == 'C':
            j_char = self.j_env[0].CallStaticCharMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = chr(<char>j_char)
        elif r == 'S':
            j_short = self.j_env[0].CallStaticShortMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <short>j_short
        elif r == 'I':
            j_int = self.j_env[0].CallStaticIntMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <int>j_int
        elif r == 'J':
            j_long = self.j_env[0].CallStaticLongMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <long>j_long
        elif r == 'F':
            j_float = self.j_env[0].CallStaticFloatMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <float>j_float
        elif r == 'D':
            j_double = self.j_env[0].CallStaticDoubleMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            ret = <double>j_double
        elif r == 'L':
            j_object = self.j_env[0].CallStaticObjectMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            if j_object != NULL:
                ret = convert_jobject_to_python(
                        self.j_env, self.definition_return, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        elif r == '[':
            r = self.definition_return[1:]
            j_object = self.j_env[0].CallStaticObjectMethodA(
                    self.j_env, self.j_cls, self.j_method, j_args)
            if j_object != NULL:
                ret = convert_jarray_to_python(self.j_env, r, j_object)
                self.j_env[0].DeleteLocalRef(self.j_env, j_object)
        else:
            raise Exception('Invalid return definition?')

        check_exception(self.j_env)
        return ret


cdef class JavaMultipleMethod(object):

    cdef LocalRef j_self
    cdef list definitions
    cdef dict static_methods
    cdef dict instance_methods
    cdef bytes name
    cdef bytes classname

    def __cinit__(self, definition, **kwargs):
        self.j_self = None

    def __init__(self, definitions, **kwargs):
        super(JavaMultipleMethod, self).__init__()
        self.definitions = definitions
        self.static_methods = {}
        self.instance_methods = {}
        self.name = None

    def __get__(self, obj, objtype):
        if obj is None:
            self.j_self = None
            return self
        # XXX FIXME we MUST not change our own j_self, but return a "bound"
        # method here, as python does!
        cdef JavaClass jc = obj
        self.j_self = jc.j_self
        return self

    cdef void set_resolve_info(self, JNIEnv *j_env, jclass j_cls,
            LocalRef j_self, bytes name, bytes classname):
        cdef JavaMethod jm
        self.name = name
        self.classname = classname

        for signature, static, is_varargs in self.definitions:
            jm = None
            if j_self is None and static:
                if signature in self.static_methods:
                    continue
                jm = JavaStaticMethod(signature, varargs=is_varargs)
                jm.set_resolve_info(j_env, j_cls, j_self, name, classname)
                self.static_methods[signature] = jm

            elif j_self is not None and not static:
                if signature in self.instance_methods:
                    continue
                jm = JavaMethod(signature, varargs=is_varargs)
                jm.set_resolve_info(j_env, j_cls, None, name, classname)
                self.instance_methods[signature] = jm

    def __call__(self, *args):
        # try to match our args to a signature
        cdef JavaMethod jm
        cdef list scores = []
        cdef dict methods

        if self.j_self:
            methods = self.instance_methods
        else:
            methods = self.static_methods

        for signature, jm in methods.iteritems():
            sign_ret, sign_args = jm.definition_return, jm.definition_args
            if jm.is_varargs:
                args_ = args[:len(sign_args) - 1] + (args[len(sign_args) - 1:],)
            else:
                args_ = args

            score = calculate_score(sign_args, args_, jm.is_varargs)

            if score <= 0:
                continue
            scores.append((score, signature))

        if not scores:
            raise JavaException('No methods matching your arguments')
        scores.sort()
        score, signature = scores[-1]

        jm = methods[signature]
        jm.j_self = self.j_self
        return jm.__call__(*args)


class JavaStaticMethod(JavaMethod):
    def __init__(self, definition, **kwargs):
        kwargs['static'] = True
        super(JavaStaticMethod, self).__init__(definition, **kwargs)


class JavaStaticField(JavaField):
    def __init__(self, definition, **kwargs):
        kwargs['static'] = True
        super(JavaStaticField, self).__init__(definition, **kwargs)


